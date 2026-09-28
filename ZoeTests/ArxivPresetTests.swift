import Foundation
import Testing
@testable import Zoe

/// Runs the bundled scripts on synthetic pages; the model stub does not test semantic quality.
@Suite(.serialized) @MainActor
struct ArxivPresetTests {
    @Test(arguments: [1, 7, 10, 12])
    func inspectedCountUsesTheBoundedSourceList(availableCount: Int) async throws {
        let url = try #require(Bundle.main.url(forResource: VerifiedPreset.arxivAI.rawValue, withExtension: "json"))
        let workflow = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: url))
        let browser = ArxivPages(availableCount: availableCount)
        let model = ArxivModelStub()
        let result = try await WorkflowRunner(browser: browser, model: model).run(workflow)
        #expect(result.status == .complete)
        let output = try #require(result.output.object)
        let inspectedCount = min(availableCount, 10)
        #expect(output["inspectedCount"] == .number(Double(inspectedCount)))
        #expect(model.inspectedCounts == [inspectedCount])
        let papers = try #require(output["papers"]?.array)
        #expect(papers.count == min(inspectedCount, 3))
        #expect(output["selectedCount"] == .number(Double(papers.count)))
        #expect(output["summarizedCount"] == .number(Double(papers.count)))
        #expect(browser.sources.count == 1 + papers.count)
        #expect(papers.allSatisfy { $0.object?["abstract"]?.text.contains("Synthetic abstract") == true })
    }

    @Test func failedSummaryDoesNotReduceInspectedCount() async throws {
        let url = try #require(Bundle.main.url(forResource: VerifiedPreset.arxivAI.rawValue, withExtension: "json"))
        let workflow = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: url))
        let model = ArxivModelStub(failsFirstSummary: true)
        let result = try await WorkflowRunner(browser: ArxivPages(availableCount: 7), model: model).run(workflow)
        #expect(result.status == .partial)
        #expect(result.output.object?["inspectedCount"] == .number(7))
        #expect(result.output.object?["selectedCount"] == .number(3))
        #expect(result.output.object?["summarizedCount"] == .number(2))
        #expect(result.output.object?["papers"]?.array?.count == 2)
        #expect(result.log.count == 1)
    }
}

@MainActor private final class ArxivModelStub: SemanticProcessing {
    private(set) var inspectedCounts: [Int] = []
    var failsFirstSummary: Bool
    init(failsFirstSummary: Bool = false) { self.failsFirstSummary = failsFirstSummary }
    func evaluate(_ task: SemanticTask, input: JSONValue, meter: RunMeter) async throws -> JSONValue {
        try meter.modelCall()
        switch task.kind {
        case .select:
            guard let records = input.array else { throw ZoeError("Expected paper records.") }
            inspectedCounts.append(records.count)
            return .array(Array(records.prefix(task.limit)))
        case .summarize:
            if failsFirstSummary {
                failsFirstSummary = false
                throw ZoeError("Synthetic summary failure")
            }
            return .string("Synthetic summary")
        case .classify:
            throw ZoeError("Unexpected classification task.")
        }
    }
}

@MainActor private final class ArxivPages: Browsing {
    static let listURL = URL(string: "https://arxiv.org/list/cs.AI/recent")!
    let availableCount: Int
    let renderer = Browser()
    private(set) var sources: [URL] = []
    var currentURL: URL? { renderer.currentURL }

    init(availableCount: Int) { self.availableCount = availableCount }

    func start(at url: URL, allowedHosts: Set<String>) async throws {
        guard url == Self.listURL else { throw ZoeError("Unexpected list URL.") }
        sources = [url]
        let records = (1...availableCount).map { index in
            let id = "2609.\(10000 + index)"
            return """
                <dt><a name="item\(index)"></a>[\(index)]
                  <a href="/abs/\(id)" title="Abstract">arXiv:\(id)</a>
                  [<a href="/pdf/\(id)" title="Download PDF">pdf</a>]</dt>
                <dd><div class="meta">
                  <div class="list-title mathjax"><span class="descriptor">Title:</span> On-device language model reasoning \(index)</div>
                  <div class="list-authors"><span class="descriptor">Authors:</span> <a href="/search/">Example Author \(index)</a></div>
                  <div class="list-subjects"><span class="descriptor">Subjects:</span> Artificial Intelligence (cs.AI)</div>
                </div></dd>
                """
        }.joined()
        try await renderer.loadFixture("<div id='dlpage'><h1>Artificial Intelligence</h1><h3>New submissions</h3><dl id='articles'>\(records)</dl></div>", at: url)
    }

    func act(_ action: BrowserAction, variables: [String: JSONValue]) async throws {
        guard action.kind == .navigate else {
            try await renderer.act(action, variables: variables)
            return
        }
        guard let address = try action.url?.resolve(in: variables).text,
              let url = URL(string: address, relativeTo: currentURL)?.absoluteURL,
              url.host() == "arxiv.org", url.path.hasPrefix("/abs/") else {
            throw ZoeError("Unexpected detail URL.")
        }
        sources.append(url)
        try await renderer.loadFixture("""
            <h1 class="title mathjax"><span class="descriptor">Title:</span> Synthetic paper</h1>
            <blockquote class="abstract mathjax"><span class="descriptor">Abstract:</span>
              Synthetic abstract for \(url.lastPathComponent). This paper describes on-device language model reasoning.
            </blockquote>
            <a href="/pdf/\(url.lastPathComponent)" class="download-pdf">Download PDF</a>
            """, at: url)
        if let wait = action.wait { try await renderer.act(.init(kind: .wait, wait: wait), variables: [:]) }
    }

    func read(_ script: String, inputs: [String: JSONValue]) async throws -> JSONValue {
        // No network requests in this fixture: inject a local timer without changing extraction/composition.
        let timer = "const setTimeout = (callback, delay, ...args) => globalThis.setTimeout(callback, 0, ...args);\n"
        return try await renderer.read(timer + script, inputs: inputs)
    }
    func stop() { renderer.stop() }
}
