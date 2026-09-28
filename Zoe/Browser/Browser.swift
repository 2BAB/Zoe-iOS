import Foundation
import Observation
import WebKit

@MainActor
protocol Browsing: AnyObject {
    var currentURL: URL? { get }
    var sources: [URL] { get }
    func start(at url: URL, allowedHosts: Set<String>) async throws
    func act(_ action: BrowserAction, variables: [String: JSONValue]) async throws
    func read(_ script: String, inputs: [String: JSONValue]) async throws -> JSONValue
    func stop()
}

@MainActor
protocol BuilderBrowsing: Browsing {
    func outline(of selector: String) async throws -> String
    func explore(_ url: URL) async throws
}

/// Dynamic pages run normally. This is an information-query policy, not a read-only JS sandbox.
@MainActor @Observable
final class Browser: BuilderBrowsing {
    private(set) var page: WebPage
    private(set) var sources: [URL] = []
    @ObservationIgnored private var policy: QueryPolicy
    @ObservationIgnored private var generation = 0
    var currentURL: URL? { page.url }

    init() {
        let policy = QueryPolicy()
        self.policy = policy
        page = Self.makePage(policy)
    }

    private static func makePage(_ policy: QueryPolicy) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.loadsSubresources = true
        configuration.defaultNavigationPreferences.allowsContentJavaScript = true
        return WebPage(configuration: configuration, navigationDecider: policy)
    }

    func start(at url: URL, allowedHosts: Set<String> = []) async throws {
        stop()
        policy = QueryPolicy()
        policy.hosts = allowedHosts.union([url.host()?.lowercased() ?? ""])
        page = Self.makePage(policy)
        sources = []
        try await load(url)
    }

    func load(_ url: URL) async throws {
        try requireAllowed(url)
        let page = self.page, generation = self.generation
        let policy = self.policy
        policy.unexpectedNavigation = nil
        policy.allowsDocumentNavigation = true
        defer { policy.allowsDocumentNavigation = false }
        try await withTimeout(seconds: 30, onCancel: { self.stopIfCurrent(generation) }) {
            for try await _ in page.load(URLRequest(url: url, timeoutInterval: 25)) {
                try Task.checkCancellation()
            }
        }
        try requireCurrent(generation)
        try checkNavigation()
        policy.documentURL = page.url
        recordSource()
    }

    /// The builder may inspect public links on other hosts; saved runs use their reviewed allowlist.
    func explore(_ url: URL) async throws {
        try Self.requirePublic(url)
        policy.hosts.insert(url.host()!.lowercased())
        try await load(url)
    }

    func act(_ action: BrowserAction, variables: [String: JSONValue]) async throws {
        try action.validate()
        let before: JSONValue?
        if let selector = action.wait?.changedSelector {
            before = try await read("const e=document.querySelector(input.selector); return e ? e.textContent : null;",
                                    inputs: ["selector": .string(selector)])
        } else { before = nil }
        switch action.kind {
        case .navigate:
            let raw = try action.url!.resolve(in: variables)
            guard case .string(let address) = raw, let url = URL(string: address, relativeTo: page.url)?.absoluteURL else {
                throw ZoeError("Navigation URL is not a string URL.")
            }
            try await load(url)
        case .wait: break
        case .click, .fill, .select, .scroll:
            var inputs: [String: JSONValue] = ["selector": .string(action.selector!), "kind": .string(action.kind.rawValue)]
            if let value = action.value { inputs["value"] = try value.resolve(in: variables) }
            _ = try await read("""
                const elements = [...document.querySelectorAll(input.selector)].filter(e => e.getClientRects().length);
                if (elements.length !== 1) throw new Error('Expected one visible target; found ' + elements.length);
                const e = elements[0];
                if (e.disabled || e.getAttribute('aria-disabled') === 'true') throw new Error('Target is disabled');
                if (input.kind === 'click') {
                  if (typeof e.click === 'function') e.click();
                  else e.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,view:window}));
                }
                if (input.kind === 'scroll') e.scrollIntoView({block:'end'});
                if (input.kind === 'fill' || input.kind === 'select') {
                  const proto = e instanceof HTMLSelectElement ? HTMLSelectElement.prototype :
                    e instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                  const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
                  if (!setter) throw new Error('Target has no supported value setter');
                  setter.call(e, String(input.value));
                  e.dispatchEvent(new Event('input', {bubbles:true}));
                  e.dispatchEvent(new Event('change', {bubbles:true}));
                }
                return true;
                """, inputs: inputs)
        }
        if let rule = action.wait { try await wait(rule, previous: before) }
        try checkNavigation()
        recordSource()
    }

    private func wait(_ rule: WaitRule, previous: JSONValue?) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(rule.timeoutSeconds))
        var lastError: String?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try checkNavigation()
            do {
                let ready = try await read(rule.script, inputs: [:])
                guard case .bool(let success) = ready else { throw ZoeError("Wait script must return a Boolean.") }
                var changed = true
                if let selector = rule.changedSelector {
                    let current = try await read("const e=document.querySelector(input.selector); return e ? e.textContent : null;",
                                                 inputs: ["selector": .string(selector)])
                    changed = current != .null && current != previous
                }
                if success && changed { return }
            } catch is CancellationError { throw CancellationError() }
            catch let error as ZoeError where error.status == .needsUser || error.status == .partial || error.stopsRun { throw error }
            catch { lastError = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw ZoeError("Page did not reach the expected state. \(lastError ?? "Completion condition timed out.")",
                       status: .needsRebuild)
    }

    func read(_ script: String, inputs: [String: JSONValue] = [:]) async throws -> JSONValue {
        try Task.checkCancellation()
        try checkNavigation()
        let page = self.page, generation = self.generation
        let result: JSONValue
        do {
            let accessCheck = """
                if ((() => {
                  const text = (document.body?.innerText || '').trim();
                  return (text.length < 1000 && /verify you are human|access denied|unusual traffic|pardon our interruption/i.test(text)) ||
                    (text.length < 80 && document.querySelector('#boxes_container') && document.querySelector('[id^="g-recaptcha-response"]'));
                })()) throw new Error('ZOE_NEEDS_USER: Site verification/access challenge; no content was read.');
                """
            result = try await withTimeout(seconds: 20, onCancel: { self.stopIfCurrent(generation) }) {
                let value = try await page.callJavaScript(accessCheck + "\n" + script,
                    arguments: ["input": JSONValue.object(inputs).foundation], contentWorld: .world(name: "Zoe"))
                try self.requireCurrent(generation)
                guard let value else { throw ZoeError("Script returned undefined; return explicit data.", status: .needsRebuild) }
                let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
                guard data.count <= 500_000 else { throw ZoeError("Read exceeds 500 KB. Narrow the extraction.") }
                return try JSONDecoder().decode(JSONValue.self, from: data)
            }
        } catch let error as WKError where error.code == .javaScriptExceptionOccurred {
            try checkNavigation()
            let detail = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw ZoeError("Page script failed: \(detail)", status: detail.contains("ZOE_NEEDS_USER:") ? .needsUser : .needsRebuild)
        }
        try requireCurrent(generation)
        try checkNavigation()
        policy.documentURL = page.url
        recordSource()
        return result
    }

    func outline(of selector: String = "body") async throws -> String {
        try await read("""
            const root=document.querySelector(input.selector);
            if(!root) throw new Error('Missing selector');
            const text=root.innerText || root.textContent || '';
            return {url:location.href,title:document.title,text:text.slice(0,7000),truncated:text.length>7000,
              links:[...root.querySelectorAll('a[href]')].slice(0,50).map(e=>({text:e.textContent.trim().slice(0,120),url:e.href})),
              controls:[...root.querySelectorAll('button,input,select,[role=button]')].slice(0,40)
                .map(e=>({tag:e.tagName,id:e.id,name:e.name,text:e.textContent.trim().slice(0,120),label:e.getAttribute('aria-label')})),
              structure:[...root.querySelectorAll('[id],[class]')].slice(0,30)
                .map(e=>({tag:e.tagName,id:e.id,class:String(e.className).slice(0,100)}))};
            """, inputs: ["selector": .string(selector)]).json
    }

    func stop() {
        generation += 1
        policy.retired = true
        page.stopLoading()
    }
    private func stopIfCurrent(_ generation: Int) {
        if self.generation == generation { stop() }
    }
    private func requireCurrent(_ generation: Int) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
    }

    #if DEBUG
    /// Real WebKit renderer, deterministic local HTML, no test server.
    func loadFixture(_ html: String, at url: URL = URL(string: "https://example.com")!) async throws {
        stop()
        policy = QueryPolicy(); policy.hosts = [url.host()!]
        page = Self.makePage(policy); sources = []
        let policy = self.policy
        policy.allowsDocumentNavigation = true
        defer { policy.allowsDocumentNavigation = false }
        for try await _ in page.load(html: html, baseURL: url) {
            try Task.checkCancellation()
        }
        policy.documentURL = page.url ?? url
    }
    #endif

    private func recordSource() {
        if let url = page.url, url.scheme == "https", !sources.contains(url) { sources.append(url) }
    }
    private func requireAllowed(_ url: URL) throws {
        try Self.requirePublic(url)
        guard policy.hosts.contains(url.host()?.lowercased() ?? "") else {
            throw ZoeError("Unreviewed destination: \(url.host() ?? ""). Rebuild to review it.", status: .needsRebuild, stopsRun: true)
        }
    }
    private func checkNavigation() throws {
        if let blocked = policy.blocked { throw ZoeError("Blocked navigation: \(blocked)", status: .needsUser) }
        if let address = policy.unexpectedNavigation {
            throw ZoeError("Page script attempted full-page navigation to \(address). Return the link and use act.navigate.",
                           status: .needsRebuild, stopsRun: true)
        }
    }

    nonisolated static func requirePublic(_ url: URL) throws {
        guard url.scheme == "https", let host = url.host()?.lowercased(), host.contains("."),
              url.user() == nil, url.password() == nil, url.port == nil || url.port == 443,
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              !host.contains(":"), host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil
        else { throw ZoeError("Use a public HTTPS address without credentials or custom ports.") }
    }
}

@MainActor
private final class QueryPolicy: WebPage.NavigationDeciding {
    var hosts: Set<String> = []
    var blocked: String?
    var unexpectedNavigation: String?
    var allowsDocumentNavigation = false
    var documentURL: URL?
    var retired = false
    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard !retired else { return .cancel }
        guard let url = action.request.url else { return .cancel }
        // Restrict document loads, not CDN/API subresources. Blank child frames do not replace the query page.
        if url.absoluteString == "about:blank" {
            if action.target?.isMainFrame == false || allowsDocumentNavigation { return .allow }
            unexpectedNavigation = url.absoluteString
            return .cancel
        }
        if action.target?.isMainFrame == false {
            return (try? Browser.requirePublic(url)) != nil ? .allow : .cancel
        }
        guard (try? Browser.requirePublic(url)) != nil, hosts.contains(url.host()?.lowercased() ?? "") else {
            blocked = url.absoluteString
            return .cancel
        }
        if !allowsDocumentNavigation {
            // Fragment links stay in this document; all other main-frame loads need the native loader.
            var destination = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var current = documentURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let fragmentChanged = destination?.fragment != current?.fragment
            destination?.fragment = nil; current?.fragment = nil
            if fragmentChanged && destination?.url == current?.url { return .allow }
            unexpectedNavigation = url.absoluteString
            return .cancel
        }
        return .allow
    }
}
