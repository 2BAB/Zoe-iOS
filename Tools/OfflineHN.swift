import Foundation

/// Synthetic HN-shaped pages for remote-build + real-local-replay tests.
/// Keep production HN URLs, but replace every page load with local HTML and a no-network CSP.
/// No live HN requests or private browser data; unknown destinations are rejected.
@MainActor final class OfflineHN: BuilderBrowsing {
    static let startURL = URL(string: "https://news.ycombinator.com/")!
    let browser = Browser()
    let titles: [String]
    private(set) var sources: [URL] = []
    var currentURL: URL? { browser.currentURL }

    // Labeled synthetic inputs are test data, not examples sent to the Builder as the user's goal.
    static let selectionCases: [(String, Bool)] = [
        ("Flip Fluid on Flip Dots", false),
        ("Fifteen years later, the Apple Cards origin story", true),
        ("Bob Mackie dressed stars–if they were brave enough", false),
        ("Apple releases a new iPhone", true),
        ("Apple harvest grows this year", false),
        ("Go Concurrency Distilled", false),
        ("Apple fixes a security vulnerability in macOS", true),
        ("Taylor Swift announces another concert", false),
        ("A guide to Swift actors and async/await on iOS", true),
        ("Microsoft releases a Windows security update", false),
        ("Apple's services revenue grows this quarter", true),
        ("How to bake an apple pie", false),
        ("Building an Android app with Kotlin", false),
        ("Developers test the new iPadOS multitasking features", true),
        ("Samsung announces its new Galaxy phone", false),
        ("Apple opens a new retail store in Singapore", true),
        ("Growing apple trees in a small garden", false),
        ("NASA publishes new images from Mars", false),
        ("Safari on macOS adds support for a new web standard", true),
        ("Linux kernel developers discuss scheduling", false),
        ("New features in Apple's Xcode IDE", true),
        ("The history of Macintosh computers", true),
        ("A database indexing tutorial for PostgreSQL", false),
        ("Apple Watch receives a watchOS update", true),
        ("Birdwatchers observe a swift building its nest", false),
        ("An interview with the creator of Python", false),
        ("Apple Music adds a new feature for subscribers", true),
        ("Google launches a new Pixel phone", false),
        ("A recipe for apple cider", false),
        ("A guide to designing accessible websites", false)
    ]
    init() { titles = Self.selectionCases.map { $0.0 } }
    func start(at url: URL, allowedHosts: Set<String>) async throws {
        sources = []
        try await load(url)
    }
    func explore(_ url: URL) async throws { try await load(url) }
    func outline(of selector: String) async throws -> String { try await browser.outline(of: selector) }
    func read(_ script: String, inputs: [String: JSONValue]) async throws -> JSONValue {
        try await browser.read(script, inputs: inputs)
    }
    func act(_ action: BrowserAction, variables: [String: JSONValue]) async throws {
        try action.validate()
        if action.kind == .navigate {
            guard let raw = try action.url?.resolve(in: variables).text,
                  let url = URL(string: raw, relativeTo: currentURL)?.absoluteURL else { throw ZoeError("Missing fixture URL.") }
            try await load(url)
            if let wait = action.wait { try await browser.act(.init(kind: .wait, wait: wait), variables: [:]) }
        } else if action.kind == .wait {
            try await browser.act(action, variables: variables)
        } else { throw ZoeError("This single-page fixture needs only navigation, reads and waits.") }
    }
    func stop() { browser.stop() }

    private func load(_ url: URL) async throws {
        guard url.host() == Self.startURL.host() else { throw ZoeError("Offline fixture cannot access other hosts.") }
        let body: String
        if url.path == "/" && url.query() == nil {
            let rows = titles.enumerated().map { index, title in
                let id = 1000 + index
                return """
                <tr class="athing" id="\(id)"><td class="titleline"><a href="https://articles.example.test/story/\(id)">\(Self.escape(title))</a></td></tr>
                <tr><td class="subtext"><span class="score">10 points</span> | <a href="item?id=\(id)">5 comments</a></td></tr>
                """
            }.joined()
            body = "<table id='hnmain'><tr><td><table id='bigbox'>\(rows)</table></td></tr></table>"
        } else {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard url.path == "/item", let id = components?.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init),
                  (1000..<1030).contains(id) else { throw ZoeError("Unknown offline page; pagination is out of scope.") }
            let comments = [
                (1, 0, "", "I love this Apple improvement. I am optimistic about its future."),
                (2, 1, "", "Nested reply, not a top-level comment."),
                (3, 0, "", "This is a disappointing step backwards. I am pessimistic about Apple's direction."),
                (4, 0, "dead", "[deleted]"),
                (5, 0, "", "The article reports that the update is scheduled for Tuesday.")
            ].map { offset, indent, extra, text in
                let commentID = id * 100 + offset
                return "<tr class='athing comtr' id='\(commentID)'><td class='ind' indent='\(indent)'><img width='\(indent * 40)'></td><td><span class='comhead'><span class='age'><a href='item?id=\(commentID)'>link</a></span></span><div class='commtext \(extra)'>\(Self.escape(text))</div></td></tr>"
            }.joined()
            body = "<table class='fatitem'><tr class='athing' id='\(id)'><td class='titleline'><a href='https://articles.example.test/story/\(id)'>\(Self.escape(titles[id - 1000]))</a></td></tr></table><table class='comment-tree'>\(comments)</table>"
        }
        let html = "<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'; connect-src 'none'; form-action 'none'\"><title>Hacker News — OFFLINE TEST FIXTURE</title></head><body>\(body)</body></html>"
        try await browser.loadFixture(html, at: url)
        if !sources.contains(url) { sources.append(url) }
    }
    func verifyScopeAndFacts(_ result: RunResult) throws {
        let expectedIDs = [1001, 1003, 1006]
        guard sources.count == 4, Set(sources.dropFirst().compactMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
        }) == Set(expectedIDs.map(String.init)) else { throw ZoeError("Offline HN replay selected the wrong stories or navigated outside its scope.") }
        // Find the relevant records by their facts, not by Builder-chosen JSON field names.
        let articles = Self.arrays(in: result.output).first { candidates in
            candidates.count == expectedIDs.count && zip(candidates, expectedIDs).allSatisfy { pair in
                pair.0.object?["title"]?.text == titles[pair.1 - 1000]
            }
        }
        guard let articles else { throw ZoeError("Expected three ordered articles with original titles.") }
        for (article, id) in zip(articles, expectedIDs) {
            guard article.json.contains("https://articles.example.test/story/\(id)") else {
                throw ZoeError("Original article URL was not preserved.")
            }
            let comments = Self.arrays(in: article).first { records in
                records.count == 3 && records.enumerated().allSatisfy { index, comment in
                        let offset = [1, 3, 5][index]
                        let label = ["optimistic", "pessimistic", "neutral"][index]
                        let body = comment.json
                        return body.contains("\(Self.startURL.absoluteString)item?id=\(id * 100 + offset)") &&
                            body.contains("\"\(label)\"") && body.contains(Self.commentText(for: offset))
                    }
            }
            guard comments != nil else {
                throw ZoeError("Comment order, original text, permalink or sentiment differs from fixture expectations.")
            }
        }
    }
    private static func arrays(in value: JSONValue) -> [[JSONValue]] {
        switch value {
        case .array(let values): return [values] + values.flatMap { arrays(in: $0) }
        case .object(let fields): return fields.values.flatMap { arrays(in: $0) }
        default: return []
        }
    }
    private static func commentText(for offset: Int) -> String {
        switch offset {
        case 1: "I love this Apple improvement. I am optimistic about its future."
        case 3: "This is a disappointing step backwards. I am pessimistic about Apple's direction."
        default: "The article reports that the update is scheduled for Tuesday."
        }
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
