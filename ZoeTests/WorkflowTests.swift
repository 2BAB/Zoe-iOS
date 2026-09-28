import Foundation
import Testing
@testable import Zoe

@MainActor
struct WorkflowTests {
    func workflow(_ steps: [Step], output: String = "result") -> Workflow {
        Workflow(title: "Test", goal: "Test", startURL: URL(string: "https://example.com")!, steps: steps, output: output)
    }
    @Test(arguments: ["hn-ai-watch", "swift-evolution", "arxiv-ai"])
    func bundledSampleAndRoundTrip(name: String) throws {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: "json"))
        let value = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: url))
        try value.validate()
        #expect(value.version == 2)
        #expect(try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(value)) == value)
    }
    @Test func jsonReferencesDoNotInterpolateCode() throws {
        let value = JSONValue.object(["item": .object(["name": .string("'; throw 42; //")])])
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(roundTrip == value)
        #expect(try ValueRef.variable("item.name").resolve(in: value.object!) == .string("'; throw 42; //"))
        #expect(throws: ZoeError.self) { try ValueRef(path: "a", literal: .null).validate() }
        #expect(throws: ZoeError.self) { try ValueRef.variable("missing").resolve(in: [:]) }
    }
    @Test func validationRejectsUnsafeBoundsAndAmbiguousActions() throws {
        #expect(throws: ZoeError.self) { try BrowserAction(kind: .click, selector: "button").validate() }
        #expect(throws: ZoeError.self) { try WaitRule(script: "return true", timeoutSeconds: 0).validate() }
        #expect(throws: ZoeError.self) { try Step.checkName("run") }
        try SemanticTask(kind: .classify, instruction: "tone", labels: ["positive", "negative"]).validate()
        let invalid = workflow([.forEach(input: .value(.array([])), item: "x", steps: [],
                                        collect: .variable("x"), output: "result", limit: 0)])
        #expect(throws: ZoeError.self) { try invalid.validate() }
    }
    @Test func publicURLValidation() {
        for address in ["http://example.com", "https://127.0.0.1", "https://[::1]", "https://example.local",
                        "https://name:password@example.com", "https://example.com:8443"] {
            #expect(throws: ZoeError.self) { try Browser.requirePublic(URL(string: address)!) }
        }
    }
    @Test func modelCallBudgetIsEnforced() throws {
        var budget = RunBudget(); budget.maxModelCalls = 1
        let meter = RunMeter(budget)
        try meter.modelCall()
        #expect(throws: ZoeError.self) { try meter.modelCall() }
    }
    @Test func emptyResultNeedsNoModel() async throws {
        let browser = FakeBrowser()
        browser.values = ["empty": .array([])]
        let result = try await WorkflowRunner(browser: browser, model: NoModel()).run(workflow([
            .read(output: "result", script: "empty", inputs: [:])
        ]))
        #expect(result.status == .complete)
        #expect(result.output == .array([]))
        #expect(browser.starts == 1)
    }
    @Test func foreachScopeAndPartialCap() async throws {
        let browser = FakeBrowser()
        browser.handler = { _, inputs in inputs["item"]! }
        let result = try await WorkflowRunner(browser: browser, model: NoModel()).run(workflow([
            .forEach(input: .value(.array([.string("a"), .string("b"), .string("c")])), item: "item",
                     steps: [.read(output: "local", script: "copy", inputs: ["item": .variable("item")])],
                     collect: .variable("local"), output: "result", limit: 2)
        ]))
        #expect(result.output == .array([.string("a"), .string("b")]))
        #expect(result.status == .partial)
    }
    @Test func loopLocalsCannotLeak() async throws {
        let browser = FakeBrowser(); browser.values["constant"] = .bool(true)
        let result = try await WorkflowRunner(browser: browser).run(workflow([
            .forEach(input: .value(.array([.number(1)])), item: "item",
                     steps: [.read(output: "secret", script: "constant", inputs: [:])],
                     collect: .variable("secret"), output: "items", limit: 1),
            .read(output: "result", script: "unused", inputs: ["bad": .variable("secret")])
        ]))
        #expect(result.status == .failed)
        #expect(result.notes.joined().contains("secret"))
    }
    @Test func stepBudgetAndErrorsAreNotEmptySuccess() async throws {
        let browser = FakeBrowser(); browser.values["ok"] = .array([])
        var task = workflow([.read(output: "result", script: "ok", inputs: [:]),
                             .read(output: "result", script: "missing", inputs: [:])])
        task.budget.maxSteps = 1
        let capped = try await WorkflowRunner(browser: browser).run(task)
        #expect(capped.status == .partial)
        task.budget.maxSteps = 5
        let failed = try await WorkflowRunner(browser: browser).run(task)
        #expect(failed.status == .needsRebuild)
    }
    @Test func storageAtomicRoundTripAndCorruptionIsNotIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "zoe-store-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(folder: directory)
        let task = workflow([.read(output: "result", script: "return [];", inputs: [:])])
        try store.save(.init(workflows: [task]))
        #expect(try store.load().workflows == [task])
        try Data("corrupt".utf8).write(to: directory.appending(path: "state.json"))
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try String(contentsOf: directory.appending(path: "state.json"), encoding: .utf8) == "corrupt")
    }
    @Test func cancellationPropagates() async throws {
        let browser = FakeBrowser()
        browser.handler = { _, _ in try await Task.sleep(for: .seconds(10)); return .null }
        let task = Task { try await WorkflowRunner(browser: browser).run(workflow([
            .read(output: "result", script: "wait", inputs: [:])
        ])) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }
}

@MainActor
private final class FakeBrowser: Browsing {
    var currentURL: URL?
    var sources: [URL] = []
    var starts = 0
    var values: [String: JSONValue] = [:]
    var handler: ((String, [String: JSONValue]) async throws -> JSONValue)?
    func start(at url: URL, allowedHosts: Set<String>) async throws { currentURL = url; sources = [url]; starts += 1 }
    func act(_ action: BrowserAction, variables: [String: JSONValue]) async throws { }
    func read(_ script: String, inputs: [String: JSONValue]) async throws -> JSONValue {
        if let handler { return try await handler(script, inputs) }
        guard let value = values[script] else { throw ZoeError("Missing fixture/container", status: .needsRebuild) }
        return value
    }
    func stop() { }
}
@MainActor private struct NoModel: SemanticProcessing {
    func evaluate(_ task: SemanticTask, input: JSONValue, meter: RunMeter) async throws -> JSONValue {
        throw ZoeError("Model should not be called")
    }
}
