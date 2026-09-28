import AppIntents
import Foundation

struct WorkflowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workflow"
    static let defaultQuery = WorkflowQuery()

    var id: UUID
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct WorkflowQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [WorkflowEntity] {
        AppModel.shared.workflows.filter { identifiers.contains($0.id) }.map(WorkflowEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [WorkflowEntity] {
        AppModel.shared.workflows.map(WorkflowEntity.init)
    }
}

extension WorkflowEntity {
    init(_ workflow: Workflow) { self.init(id: workflow.id, title: workflow.title) }
}

/// Opens Zoe and runs a saved workflow on device. The reliable path for automations.
struct RunWorkflowIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Workflow"
    static let description = IntentDescription("Opens Zoe and runs a saved workflow with the on-device model.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Workflow") var workflow: WorkflowEntity

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$workflow)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await AppModel.shared.run(workflowID: workflow.id))
    }
}

/// Runs a saved workflow without opening Zoe, using the iOS 27 long-running intent API.
/// Experimental: background WebKit loading and model inference still need testing on a locked iPhone.
struct RunWorkflowInBackgroundIntent: LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Run Workflow in Background"
    static let description = IntentDescription(
        "Runs a saved workflow in the background with system progress and cancellation. Experimental.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Workflow") var workflow: WorkflowEntity

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$workflow) in the background") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = workflow.id
        let text = try await performBackgroundTask {
            try await AppModel.shared.run(workflowID: id)
        } onCancel: { _ in
            Task { @MainActor in AppModel.shared.cancel() }
        }
        return .result(value: text)
    }
}
