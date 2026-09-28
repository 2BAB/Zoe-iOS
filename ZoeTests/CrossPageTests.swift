import Foundation
import Testing
@testable import Zoe

/// Tests the host boundary with ordinary records, independent of any site's preset or headline wording.
@Suite(.serialized) @MainActor
struct CrossPageTests {
    @Test(arguments: [false, true])
    func javaScriptFailureSkipsOnlyThatDetailPage(missingMiddle: Bool) async throws {
        let browser = FixturePages(missingMiddle: missingMiddle)
        let workflow = Workflow(title: "Details", goal: "Read details", startURL: FixturePages.listURL,
            steps: [
                .read(output: "records", script: """
                    const links = [...document.querySelectorAll('a.record')];
                    if (!links.length) throw new Error('Missing records');
                    return links.map(link => ({name: link.textContent.trim(), url: link.href}));
                    """, inputs: [:]),
                .forEach(input: .variable("records"), item: "record", steps: [
                    .act(action: .init(kind: .navigate, url: .variable("record.url"))),
                    .read(output: "detail", script: """
                        const value = document.querySelector('#value');
                        if (!value) throw new Error('Missing detail');
                        return {name:input.record.name, value:value.textContent.trim(), url:location.href};
                        """, inputs: ["record": .variable("record")])
                ], collect: .variable("detail"), output: "details", limit: 3),
                .read(output: "result", script: "return input.details;", inputs: ["details": .variable("details")])
            ])
        let result = try await WorkflowRunner(browser: browser).run(workflow)
        #expect(result.status == (missingMiddle ? .partial : .complete))
        #expect(browser.visited == [FixturePages.listURL] + (1...3).map(FixturePages.detailURL))
        #expect(result.output.array?.compactMap { $0.object?["value"]?.text } ==
                (missingMiddle ? ["First", "Third"] : ["First", "Second", "Third"]))
        #expect(result.log.count == (missingMiddle ? 1 : 0))
        if missingMiddle {
            #expect(result.log[0].contains("details[1]"))
            #expect(result.log[0].contains("Missing detail"))
        }
    }
}

@MainActor
private final class FixturePages: Browsing {
    static let listURL = URL(string: "https://example.com/records")!
    static func detailURL(_ id: Int) -> URL { URL(string: "https://example.com/record/\(id)")! }

    private let renderer = Browser()
    let missingMiddle: Bool
    init(missingMiddle: Bool) { self.missingMiddle = missingMiddle }
    private(set) var visited: [URL] = []
    var currentURL: URL? { visited.last }
    var sources: [URL] { visited }

    func start(at url: URL, allowedHosts: Set<String>) async throws {
        guard url == Self.listURL else { throw ZoeError("Unexpected start page") }
        visited = [url]
        try await renderer.loadFixture("""
            <h1>Records</h1>
            <a class='record' href='/record/1'>One</a>
            <a class='record' href='/record/2'>Two</a>
            <a class='record' href='/record/3'>Three</a>
            """, at: url)
    }

    func act(_ action: BrowserAction, variables: [String: JSONValue]) async throws {
        guard action.kind == .navigate, let reference = action.url,
              case .string(let address) = try reference.resolve(in: variables),
              let url = URL(string: address), (1...3).map(Self.detailURL).contains(url) else {
            throw ZoeError("Unexpected navigation")
        }
        visited.append(url)
        let value = url == Self.detailURL(1) ? "First" : url == Self.detailURL(2) ? "Second" : "Third"
        let html = missingMiddle && url == Self.detailURL(2) ? "<h1>Unavailable</h1>" : "<div id='value'>\(value)</div>"
        try await renderer.loadFixture(html, at: url)
    }

    func read(_ script: String, inputs: [String: JSONValue]) async throws -> JSONValue {
        try await renderer.read(script, inputs: inputs)
    }
    func stop() { renderer.stop() }
}
