import Foundation

struct WorkflowStore {
    let folder: URL
    struct State: Codable {
        var workflows: [Workflow] = []
        var results: [UUID: RunResult] = [:]
    }
    private var file: URL { folder.appending(path: "state.json") }

    func load() throws -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return State() }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        try state.workflows.forEach { try $0.validate() }
        return state
    }
    func save(_ state: State) throws {
        try state.workflows.forEach { try $0.validate() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(state).write(to: file, options: .atomic)
    }
}
