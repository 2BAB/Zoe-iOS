import Foundation
import FoundationModels
import Observation

/// Bundled workflows generated and verified by the remote builder.
enum VerifiedPreset: String, CaseIterable, Identifiable {
    case hackerNews = "hn-ai-watch"
    case swiftEvolution = "swift-evolution"
    case arxivAI = "arxiv-ai"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hackerNews: "Hacker News"
        case .swiftEvolution: "Swift Evolution"
        case .arxivAI: "arXiv Papers"
        }
    }
    var symbol: String {
        switch self {
        case .hackerNews: "newspaper"
        case .swiftEvolution: "swift"
        case .arxivAI: "doc.text.magnifyingglass"
        }
    }
}

/// App state. Buttons and Shortcuts share it, so only one build or run happens at a time.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var workflows: [Workflow] = []
    var selectedID: Workflow.ID?
    var draft: Workflow?
    var results: [Workflow.ID: RunResult] = [:]

    var goal = ""
    var startURL = ""
    var builder = BuilderModel.gemini
    /// Kept in memory only. Set `GEMINI_API_KEY` in the scheme's environment to prefill it.
    var geminiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    var geminiModel = "gemini-3.8-flash"

    private(set) var isBusy = false
    private(set) var log: [String] = []
    var status = "Choose a workflow or try a verified sample."
    var errorMessage: String?

    let browser = Browser()
    @ObservationIgnored private var cancelCurrent: (() -> Void)?
    private let store = WorkflowStore(folder: URL.applicationSupportDirectory.appending(path: "Zoe", directoryHint: .isDirectory))
    private var storageReady = true

    var selectedWorkflow: Workflow? { workflows.first { $0.id == selectedID } }

    var modelStatus: String {
        let model = SystemLanguageModel.default
        let state = switch model.availability {
        case .available: "\(model.contextSize) tokens, ready"
        case .unavailable(.modelNotReady): "downloading or not ready yet"
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off"
        case .unavailable(.deviceNotEligible): "not supported on this device"
        case .unavailable: "unavailable"
        }
        return "\(model.variant.displayName): \(state)"
    }

    init() {
        do {
            let state = try store.load()
            workflows = state.workflows; results = state.results
        } catch {
            storageReady = false
            errorMessage = "Saved data couldn't be loaded. Original files were preserved: \(error.localizedDescription)"
        }
    }

    // MARK: Workflows

    func loadSample(_ preset: VerifiedPreset) {
        guard let url = Bundle.main.url(forResource: preset.rawValue, withExtension: "json"),
              let sample = try? JSONDecoder().decode(Workflow.self, from: Data(contentsOf: url)) else {
            errorMessage = "The sample workflow is missing from the app bundle."
            return
        }
        showDraft(sample, status: "Review the sample steps, then save it.")
    }

    func saveDraft() {
        guard let draft else { return }
        var updated = workflows.filter { $0.id != draft.id }
        updated.insert(draft, at: 0)
        do {
            try persist(workflows: updated, results: results)
            workflows = updated
            selectedID = draft.id
            self.draft = nil
            status = "Saved. Run it here or from Shortcuts."
        } catch { report(error) }
    }

    func delete(_ workflow: Workflow) {
        let updated = workflows.filter { $0.id != workflow.id }
        var newResults = results; newResults[workflow.id] = nil
        do {
            try persist(workflows: updated, results: newResults)
            workflows = updated; results = newResults
            if selectedID == workflow.id { selectedID = nil }
        } catch { report(error) }
    }

    // MARK: Build and run

    func build() {
        guard let url = URL(string: startURL.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "Enter a valid start URL."
            return
        }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            errorMessage = "Describe what Zoe should find."
            return
        }
        let runner = makeRunner()
        let choice = builder, key = geminiKey, modelName = geminiModel
        start("Building and verifying…") {
            let workflow = switch choice {
            case .gemini:
                try await WorkflowBuilder.build(goal: goal, startURL: url, model: GeminiLanguageModel(apiKey: key, model: modelName),
                                                runner: runner, log: self.append)
            case .privateCloudCompute:
                try await WorkflowBuilder.build(goal: goal, startURL: url, model: PrivateCloudComputeLanguageModel(),
                                                runner: runner, log: self.append)
            }
            self.showDraft(workflow, status: "The workflow was independently replayed. Review its output and run log before saving.")
        }
    }

    func runSelected() {
        guard let workflow = selectedWorkflow else { return }
        start("Running on device…") { _ = try await self.execute(workflow) }
    }

    /// Entry point for Shortcuts. Returns the result as text.
    func run(workflowID: Workflow.ID) async throws -> String {
        guard !isBusy else { throw ZoeError("Zoe is busy with another workflow.") }
        guard let workflow = workflows.first(where: { $0.id == workflowID }) else {
            throw ZoeError("That workflow no longer exists.")
        }
        selectedID = workflow.id
        begin("Running from Shortcuts…")
        defer { isBusy = false; cancelCurrent = nil }
        let operation = Task { try await self.execute(workflow) }
        cancelCurrent = { operation.cancel() }
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            return Self.text(for: result)
        } catch {
            report(error)
            throw error
        }
    }

    func cancel() {
        cancelCurrent?()
        browser.stop()
    }

    private func execute(_ workflow: Workflow) async throws -> RunResult {
        let result = try await makeRunner().run(workflow)
        var updated = results; updated[workflow.id] = result
        try persist(workflows: workflows, results: updated)
        results = updated
        status = Self.statusText(for: result)
        return result
    }

    private func makeRunner() -> WorkflowRunner {
        let log: (String) -> Void = { [weak self] in self?.append($0) }
        return WorkflowRunner(browser: browser, model: OnDeviceModel(log: log), log: log)
    }

    private func start(_ message: String, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        begin(message)
        let task = Task {
            defer { isBusy = false; cancelCurrent = nil }
            do { try await operation() } catch { report(error) }
        }
        cancelCurrent = { task.cancel() }
    }

    private func begin(_ message: String) {
        isBusy = true
        log = []
        errorMessage = nil
        status = message
    }

    private func report(_ error: any Error) {
        if error is CancellationError || Task.isCancelled {
            status = "Cancelled."
        } else {
            status = "Didn't finish."
            errorMessage = error.localizedDescription
            append("Error: \(error.localizedDescription)")
        }
    }

    private func append(_ line: String) { log.append(line) }

    private func showDraft(_ workflow: Workflow, status: String) {
        draft = workflow
        selectedID = nil
        goal = workflow.goal
        startURL = workflow.startURL.absoluteString
        self.status = status
    }

    // MARK: Storage

    private func persist(workflows: [Workflow], results: [UUID: RunResult]) throws {
        guard storageReady else { throw ZoeError("Resolve the saved-data error before overwriting storage.") }
        try store.save(.init(workflows: workflows, results: results))
    }

    static func statusText(for result: RunResult) -> String {
        switch result.status {
        case .complete:
            if let records = result.output.array { return "Run finished — \(records.count) records returned." }
            return "Run finished."
        case .partial: return "Run partially completed. Check the notes."
        case .failed: return "Run failed. Check the notes."
        case .needsUser: return "Run needs your attention. Check the notes."
        case .needsRebuild: return "Workflow needs rebuilding. Check the notes."
        }
    }

    static func text(for result: RunResult) -> String {
        (["Status: \(result.status.rawValue)"] + result.notes + [result.output.json]
            + (result.log.isEmpty ? [] : ["Run log:", result.log.joined(separator: "\n")])
            + (result.completedCollections.isEmpty ? [] : ["Completed collections (unfinished run):", JSONValue.object(result.completedCollections).json])
            + result.sources.map(\.absoluteString)).joined(separator: "\n\n")
    }
}
