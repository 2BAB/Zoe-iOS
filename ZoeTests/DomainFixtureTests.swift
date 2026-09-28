import Foundation
import Testing
@testable import Zoe

/// Same engine, three business shapes. Fixtures are not claims of live-site coverage.
@Suite(.serialized) @MainActor
struct DomainFixtureTests {
    @Test func movieDateSelectionAndVerifiedEmptyState() async throws {
        let browser = FixtureBrowser(html: """
        <h1>Example Movie</h1><select id="date" onchange="document.querySelector('#empty').hidden=false;document.querySelector('#sessions').textContent=''">
        <option>Today</option><option>Tomorrow</option></select>
        <div id="sessions">19:30</div><div id="empty" hidden>No sessions for this date</div>
        """)
        let task = Workflow(title: "Movie", goal: "Query", startURL: URL(string: "https://example.com")!, steps: [
            .act(action: .init(kind: .select, selector: "#date", value: .value(.string("Tomorrow")),
                              wait: .init(script: "return document.querySelector('#empty').hidden===false;"))),
            .read(output: "result", script: """
                const sessions=document.querySelector('#sessions'), empty=document.querySelector('#empty');
                if(!sessions || !empty || empty.hidden || sessions.textContent.trim()) throw new Error('Empty state not verified');
                return {date:document.querySelector('#date').value,sessions:[],
                  evidence:empty.textContent,source:location.href};
                """, inputs: [:])
        ])
        let result = try await WorkflowRunner(browser: browser).run(task)
        #expect(result.status == .complete)
        #expect(result.output.object?["sessions"] == .array([]))
        #expect(result.output.object?["date"] == .string("Tomorrow"))
        #expect(result.output.object?["evidence"] == .string("No sessions for this date"))
    }
    @Test(arguments: [true, false])
    func reportVersionDecisionInJavaScript(published: Bool) async throws {
        let link = published ? "<a id='full' href='/report-v2.pdf'>Full report, version 2</a>" : "<p id='pending'>Full version forthcoming</p>"
        let browser = FixtureBrowser(html: "<h1 id='project'>Research Project</h1>\(link)")
        let task = Workflow(title: "Report", goal: "Query", startURL: URL(string: "https://example.com")!, steps: [
            .read(output: "result", script: """
                if (!document.querySelector('#project')) throw new Error('Wrong page');
                const link = document.querySelector('#full');
                if (link) return {status:'available',url:link.href};
                if (document.querySelector('#pending')) return {status:'not published',url:location.href};
                throw new Error('Unknown state');
                """, inputs: [:])
        ])
        let result = try await WorkflowRunner(browser: browser).run(task)
        #expect(result.status == .complete)
        #expect(result.output.object?["status"] == .string(published ? "available" : "not published"))
        if published { #expect(result.output.object?["url"] == .string("https://example.com/report-v2.pdf")) }
    }
}
@MainActor
private final class FixtureBrowser: Browsing {
    let html: String
    let real = Browser()
    init(html: String) { self.html = html }
    var currentURL: URL? { real.currentURL }
    var sources: [URL] { real.sources }
    func start(at url: URL, allowedHosts: Set<String>) async throws { try await real.loadFixture(html) }
    func read(_ script: String, inputs: [String: JSONValue]) async throws -> JSONValue { try await real.read(script, inputs: inputs) }
    func act(_ action: BrowserAction, variables: [String: JSONValue]) async throws { try await real.act(action, variables: variables) }
    func stop() { real.stop() }
}
