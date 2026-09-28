import Foundation
import FoundationModels
import Testing
@testable import Zoe

@MainActor
struct RuntimeContractTests {
    private func workflow(_ steps: [Step]) -> Workflow {
        Workflow(title: "Runtime contract", goal: "Offline", startURL: URL(string: "https://example.com")!, steps: steps)
    }

    @Test func builderOwnsWorkflowMetadata() throws {
        let startURL = URL(string: "https://example.com/")!
        let candidate = #"{"title":"Example","steps":[{"read":{"output":"result","script":"return null;","inputs":{}}}]}"#
        let workflow = try Draft.decodeCandidate(candidate, goal: "Find something", startURL: startURL)
        #expect(workflow.version == 2)
        #expect(workflow.goal == "Find something")
        #expect(workflow.startURL == startURL)
        try workflow.validate()

        let wrongURL = #"{"title":"Example","startURL":"https://other.example.com/","steps":[{"read":{"output":"result","script":"return null;","inputs":{}}}]}"#
        #expect(throws: ZoeError.self) { try Draft.decodeCandidate(wrongURL, goal: "Find something", startURL: startURL) }
        let suppliedMetadata = #"{"title":"Example","version":99,"goal":"Not the user goal","steps":[{"read":{"output":"result","script":"return null;","inputs":{}}}]}"#
        let normalized = try Draft.decodeCandidate(suppliedMetadata, goal: "Find something", startURL: startURL)
        #expect(normalized.version == 2)
        #expect(normalized.goal == "Find something")
    }

    @Test func secondModelCallFailurePreservesCompletedCollection() async throws {
        let browser = ContractBrowser()
        var task = workflow([
            .forEach(input: .value(.array([.string("first"), .string("second")])), item: "item",
                steps: [.semantic(output: "answer", input: .variable("item"),
                    task: .init(kind: .summarize, instruction: "copy"))],
                collect: .variable("answer"), output: "articles", limit: 2),
            .read(output: "result", script: "compose", inputs: ["articles": .variable("articles")])
        ])
        task.budget.maxModelCalls = 1
        let result = try await WorkflowRunner(browser: browser, model: CountingModel()).run(task)
        #expect(result.status == .partial)
        #expect(result.output == .null)
        #expect(result.completedCollections["articles"] == .array([.string("first")]))
        #expect(browser.reads.isEmpty) // No final answer was invented.
        let decoded = try JSONDecoder().decode(RunResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.completedCollections == result.completedCollections)
        #expect(decoded.output == .null)
    }

    @Test(arguments: ["unfinished", "verified", "finished"])
    func builderClosingErrorOnlyPreservesAFinishedWorkflow(stage: String) async throws {
        let browser = Browser()
        let draft = Draft(goal: "Test", startURL: URL(string: "https://example.com")!,
                          runner: WorkflowRunner(browser: ContractBrowser(), model: CountingModel()),
                          browser: browser, log: { _ in })
        let candidate = #"{"title":"Test","steps":[{"read":{"output":"result","script":"compose","inputs":{"articles":{"literal":["ok"]}}}}]}"#
        do {
            let completed = try await draft.completeBuild {
                if stage != "unfinished" { _ = try await draft.verify(candidate) }
                if stage == "finished" { _ = try await draft.finish() }
                throw ZoeError("Closing response could not be parsed")
            }
            #expect(stage == "finished")
            #expect(completed == draft.verified)
        } catch {
            #expect(stage != "finished")
            #expect(error.localizedDescription == "Closing response could not be parsed")
        }
        if stage == "finished" {
            do {
                _ = try await draft.completeBuild { throw CancellationError() }
                Issue.record("Cancellation must not become a completed build")
            } catch is CancellationError { }
        }
    }

    @Test func nestedCollectionHasAnUnambiguousCheckpointPath() async throws {
        var task = workflow([
            .forEach(input: .value(.array([.number(1)])), item: "article",
                steps: [.forEach(input: .value(.array([.string("a"), .string("b")])), item: "comment",
                    steps: [.semantic(output: "answer", input: .variable("comment"),
                        task: .init(kind: .summarize, instruction: "copy"))],
                    collect: .variable("answer"), output: "comments", limit: 2)],
                collect: .variable("comments"), output: "articles", limit: 1)
        ])
        task.budget.maxModelCalls = 1
        let result = try await WorkflowRunner(browser: ContractBrowser(), model: CountingModel()).run(task)
        #expect(result.completedCollections["articles[0].comments"] == .array([.string("a")]))
        #expect(result.completedCollections["articles"] == nil)
    }

    @Test func failedMiddleItemDoesNotBecomeALabelOrStopLaterItems() async throws {
        let task = workflow([
            .forEach(input: .value(.array([.string("first"), .string("blocked"), .string("third")])), item: "item",
                steps: [.semantic(output: "answer", input: .variable("item"),
                    task: .init(kind: .classify, instruction: "Use the given labels", labels: ["positive", "negative"]))],
                collect: .variable("answer"), output: "answers", limit: 3),
            .read(output: "result", script: "compose", inputs: ["answers": .variable("answers")])
        ])
        let result = try await WorkflowRunner(browser: ContractBrowser(), model: IsolatingModel()).run(task)
        #expect(result.status == .partial)
        #expect(result.output.object?["answers"] == .array([.string("positive"), .string("positive")]))
        #expect(result.log.count == 1)
        #expect(result.log[0].contains("answers[1]"))
        #expect(result.log[0].contains("Guardrail"))
        #expect(result.output.object?["issues"] == nil)
        let decoded = try JSONDecoder().decode(RunResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.log == result.log)
    }

    @Test func builderOnlyAcceptsLoggedIsolatedPartialResults() {
        let note = RunResult.isolatedItemNote
        let disclosed = RunResult(output: .array([.string("ok")]),
                                  status: .partial, notes: [note], log: ["Skipped items[1]: Guardrail"])
        #expect(disclosed.builderVerificationAccepted)
        var hidden = disclosed
        hidden.log = []
        #expect(!hidden.builderVerificationAccepted)
        var capped = disclosed
        capped.notes.append("Model-call budget reached.")
        #expect(!capped.builderVerificationAccepted)
        #expect(!RunResult(output: .null, status: .complete).builderVerificationAccepted)
    }

    @Test func malformedSelectionRecordDoesNotDiscardTheHealthyPrefix() throws {
        let task = SemanticTask(kind: .select, instruction: "Relevant", fields: ["title"])
        let records: [JSONValue] = [.object(["title": .string("First")]), .object(["other": .string("Bad")]),
                                    .object(["title": .string("Third")])]
        #expect(try OnDeviceModel.selectionPrefix(task, items: records[...]) == [records[0]])
        #expect(throws: ZoeError.self) { try OnDeviceModel.selectionPrefix(task, items: records[1...]) }
        #expect(try OnDeviceModel.selectionPrefix(task, items: records[2...]) == [records[2]])
        let many = Array(repeating: records[0], count: 30)
        #expect(try OnDeviceModel.selectionPrefix(task, items: many[...]).count == 10)
    }

    @Test func maximumLengthSelectionInstructionCanBeWrapped() throws {
        let task = SemanticTask(kind: .select, instruction: String(repeating: "a", count: 2000), fields: ["title"])
        try task.validate()
        let batch = try OnDeviceModel.selectionBatch(task, items: [.object(["title": .string("Example")])])
        #expect(batch.request.instructions == OnDeviceModel.boundary + "\n\n" + task.instruction)
        #expect(batch.records[0].object?["data"] == .object(["title": .string("Example")]))
        #expect(!batch.request.prompt.contains(task.instruction))
        #expect(throws: ZoeError.self) { try OnDeviceModel.selectionBatch(task, items: []) }
        #expect(throws: ZoeError.self) {
            try OnDeviceModel.selectionBatch(task, items: Array(repeating: .null, count: OnDeviceModel.maximumBatchRecords + 1))
        }
    }

    @Test func deadlineReturnsWithoutWaitingForUncooperativeWork() async throws {
        let gate = SuspendedOperation()
        defer { gate.resume() }
        var cancelled = false
        let start = ContinuousClock.now
        do {
            _ = try await withTimeout(after: .milliseconds(40), onCancel: { cancelled = true }) {
                await gate.wait()
            }
            Issue.record("Expected deadline")
        } catch let error as ZoeError { #expect(error.status == .partial) }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(cancelled)
        #expect(gate.continuation != nil) // Caller returned while dependency is still suspended.
    }

    @Test func selectionKeysKeepDuplicatesAndQuotedTextDistinct() throws {
        let title = "Quoted \"title\"\nApple (café) 😀"
        let task = SemanticTask(kind: .select, instruction: "Match the quoted text", fields: ["title"])
        let item = JSONValue.object(["title": .string(title), "url": .string("https://example.com")])
        let batch = try OnDeviceModel.selectionBatch(task, items: [item, item])
        #expect(batch.records.map { $0.object?["id"] } == [.number(0), .number(1)])
        #expect(batch.records.allSatisfy { $0.object?["data"] == .object(["title": .string(title)]) })
        #expect(!batch.request.prompt.contains("https://example.com")) // Only reviewed semantic fields enter the model.
    }

    @Test func selectionRejectsInvalidModelIDs() throws {
        try OnDeviceModel.validateSelection(matches: [2, 0], count: 3)
        try OnDeviceModel.validateSelection(matches: [], count: 3)
        for matches in [[0, 0], [-1], [3]] {
            #expect(throws: ZoeError.self) { try OnDeviceModel.validateSelection(matches: matches, count: 3) }
        }
    }

    @Test func classificationLabelsDoNotRequireUnknown() throws {
        try SemanticTask(kind: .classify, instruction: "Tone", labels: ["positive", "negative"]).validate()
        #expect(throws: ZoeError.self) {
            try SemanticTask(kind: .classify, instruction: "Tone", labels: ["positive", "positive"]).validate()
        }
    }

    @Test func selectionRejectsDuplicateFieldsAndBuildsTenRecordRequest() throws {
        #expect(throws: ZoeError.self) {
            try SemanticTask(kind: .select, instruction: "Task", fields: ["title", "title"]).validate()
        }
        let batch = try OnDeviceModel.selectionBatch(.init(kind: .select, instruction: "Builder's complete criterion", fields: ["title"]),
            items: Array(repeating: .object(["title": .string("Example")]), count: 10))
        #expect(batch.records.count == 10)
    }

    @Test func cancellationReturnsWithoutWaitingForUncooperativeWork() async throws {
        let gate = SuspendedOperation()
        defer { gate.resume() }
        let task = Task {
            try await withTimeout(seconds: 10) { await gate.wait() }
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(gate.continuation != nil)
    }

    @Test func timedOutRunCannotResumeActionsOrOverwriteANewRun() async throws {
        let browser = ContractBrowser()
        let runner = WorkflowRunner(browser: browser, model: CountingModel())
        var task = workflow([
            .read(output: "result", script: "suspended", inputs: [:]),
            .read(output: "result", script: "must-not-run", inputs: [:])
        ])
        task.budget.maxSeconds = 1
        defer { browser.gate.resume() }
        let started = ContinuousClock.now
        let expired = try await runner.run(task)
        #expect(expired.status == .partial)
        #expect(started.duration(to: .now) < .seconds(2))
        let fresh = try await runner.run(workflow([.read(output: "result", script: "fresh", inputs: [:])]))
        #expect(fresh.output == .string("fresh"))
        browser.gate.resume()
        try await Task.sleep(for: .milliseconds(30))
        #expect(browser.reads == ["suspended", "fresh"])
        #expect(browser.stops > 0)
    }

}

@MainActor private final class SuspendedOperation {
    var continuation: CheckedContinuation<JSONValue, Never>?
    func wait() async -> JSONValue {
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(returning: .string("late")); continuation = nil }
}

@MainActor private final class ContractBrowser: Browsing {
    var currentURL: URL?
    var sources: [URL] = []
    var reads: [String] = []
    var stops = 0
    let gate = SuspendedOperation()
    func start(at url: URL, allowedHosts: Set<String>) async throws { currentURL = url; sources = [url] }
    func act(_ action: BrowserAction, variables: [String: JSONValue]) async throws { }
    func read(_ script: String, inputs: [String: JSONValue]) async throws -> JSONValue {
        reads.append(script)
        if script == "suspended" { return await gate.wait() }
        if script == "compose" {
            return .object(["answers": inputs["answers"] ?? .null])
        }
        return .string(script)
    }
    func stop() { stops += 1 }
}

@MainActor private struct CountingModel: SemanticProcessing {
    func evaluate(_ task: SemanticTask, input: JSONValue, meter: RunMeter) async throws -> JSONValue {
        try meter.modelCall()
        return input
    }
}

@MainActor private struct IsolatingModel: SemanticProcessing {
    func evaluate(_ task: SemanticTask, input: JSONValue, meter: RunMeter) async throws -> JSONValue {
        try meter.modelCall()
        if input == .string("blocked") { throw ZoeError("Guardrail blocked this item") }
        return .string("positive")
    }
}
