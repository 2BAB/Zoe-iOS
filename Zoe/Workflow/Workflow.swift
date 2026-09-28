import Foundation

struct Workflow: Codable, Identifiable, Hashable, Sendable {
    var version = 2
    var id = UUID()
    var title: String
    var goal: String
    var startURL: URL
    var allowedHosts: [String] = []
    var parameters: [String: JSONValue] = [:]
    var steps: [Step]
    var output = "result"
    var budget = RunBudget()

    var hosts: Set<String> { Set(allowedHosts.map { $0.lowercased() } + [startURL.host()?.lowercased() ?? ""]) }

    func validate() throws {
        guard version == 2 else { throw ZoeError("Unsupported workflow version \(version).") }
        try Browser.requirePublic(startURL)
        guard !steps.isEmpty, steps.count <= 100, !title.isEmpty, !output.isEmpty else {
            throw ZoeError("A workflow needs a title, 1–100 steps, and an output variable.")
        }
        for host in hosts {
            guard let url = URL(string: "https://\(host)"), url.host() == host, url.path.isEmpty else {
                throw ZoeError("Invalid allowed host.")
            }
            try Browser.requirePublic(url)
        }
        try budget.validate()
        for name in parameters.keys { try Step.checkName(name) }
        var count = 0
        try Step.validate(steps, depth: 0, count: &count)
    }

    enum CodingKeys: String, CodingKey { case version, id, title, goal, startURL, allowedHosts, parameters, steps, output, budget }
    init(title: String, goal: String, startURL: URL, steps: [Step], output: String = "result") {
        self.title = title; self.goal = goal; self.startURL = startURL; self.steps = steps; self.output = output
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        goal = try c.decode(String.self, forKey: .goal)
        startURL = try c.decode(URL.self, forKey: .startURL)
        allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        parameters = try c.decodeIfPresent([String: JSONValue].self, forKey: .parameters) ?? [:]
        steps = try c.decode([Step].self, forKey: .steps)
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? "result"
        budget = try c.decodeIfPresent(RunBudget.self, forKey: .budget) ?? RunBudget()
    }
}

/// Swift keeps only the operations that cross a page or model boundary.
indirect enum Step: Codable, Hashable, Sendable {
    case act(action: BrowserAction)
    case read(output: String, script: String, inputs: [String: ValueRef])
    case forEach(input: ValueRef, item: String, steps: [Step], collect: ValueRef, output: String, limit: Int)
    case semantic(output: String, input: ValueRef, task: SemanticTask)

    var title: String {
        switch self {
        case .act(let action): "\(action.kind.rawValue): \(action.selector ?? action.url?.path ?? action.url?.literal?.text ?? "")"
        case .read(let output, _, _): "Read → \(output)"
        case .forEach(_, _, _, _, let output, let limit): "For each (up to \(limit)) → \(output)"
        case .semantic(let output, _, let task): "\(task.kind.rawValue) on device → \(output)"
        }
    }
    var detail: String { (try? String(decoding: JSONEncoder.pretty.encode(self), as: UTF8.self)) ?? title }

    static func checkName(_ name: String) throws {
        guard name.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil,
              name != "run" else { throw ZoeError("Invalid or reserved variable name: \(name)") }
    }
    static func validate(_ steps: [Step], depth: Int, count: inout Int) throws {
        guard depth <= 5 else { throw ZoeError("Workflow nesting exceeds 5.") }
        for step in steps {
            count += 1
            guard count <= 100 else { throw ZoeError("More than 100 step definitions.") }
            switch step {
            case .act(let action): try action.validate()
            case .read(let output, let script, let inputs):
                try checkName(output)
                guard !script.isEmpty, script.utf8.count <= 30_000 else { throw ZoeError("Invalid read script size.") }
                for ref in inputs.values { try ref.validate() }
            case .forEach(let input, let item, let children, let collect, let output, let limit):
                try input.validate(); try collect.validate(); try checkName(item); try checkName(output)
                guard (1...200).contains(limit), !children.isEmpty else { throw ZoeError("Invalid forEach bounds.") }
                try validate(children, depth: depth + 1, count: &count)
            case .semantic(let output, let input, let task):
                try checkName(output); try input.validate(); try task.validate()
            }
        }
    }
}

struct BrowserAction: Codable, Hashable, Sendable {
    enum Kind: String, Codable { case navigate, click, fill, select, scroll, wait }
    var kind: Kind
    var url: ValueRef?
    var selector: String?
    var value: ValueRef?
    var wait: WaitRule?
    func validate() throws {
        if kind == .navigate { guard let url else { throw ZoeError("navigate needs a URL.") }; try url.validate() }
        if [.click, .fill, .select, .scroll].contains(kind) {
            guard let selector, !selector.isEmpty else { throw ZoeError("An action needs a unique selector.") }
        }
        if [.fill, .select].contains(kind) {
            guard let value else { throw ZoeError("fill/select needs a value.") }; try value.validate()
        }
        if kind != .navigate && wait == nil { throw ZoeError("An interaction needs an explicit completion condition.") }
        try wait?.validate()
    }
}

struct WaitRule: Codable, Hashable, Sendable {
    /// A JS function body returning a Boolean. Throw for an unexpected page.
    var script: String
    /// When present, this element's text must also change from the pre-action snapshot.
    var changedSelector: String?
    var timeoutSeconds: Int = 15
    func validate() throws {
        guard !script.isEmpty, script.count <= 5000, (1...30).contains(timeoutSeconds) else {
            throw ZoeError("Invalid wait rule.")
        }
    }
}

struct SemanticTask: Codable, Hashable, Sendable {
    enum Kind: String, Codable { case select, classify, summarize }
    var kind: Kind
    var instruction: String
    var labels: [String] = []
    /// select sees these fields only; the returned objects are always the original Swift values.
    var fields: [String] = []
    var limit: Int = 10

    enum CodingKeys: String, CodingKey { case kind, instruction, labels, fields, limit }
    init(kind: Kind, instruction: String, labels: [String] = [], fields: [String] = [], limit: Int = 10) {
        self.kind = kind; self.instruction = instruction; self.labels = labels; self.fields = fields; self.limit = limit
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        instruction = try c.decode(String.self, forKey: .instruction)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        fields = try c.decodeIfPresent([String].self, forKey: .fields) ?? []
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 10
    }
    func validate() throws {
        guard !instruction.isEmpty, instruction.count <= 2000, (1...200).contains(limit) else {
            throw ZoeError("Invalid semantic task.")
        }
        if kind == .classify {
            guard (2...8).contains(labels.count), Set(labels).count == labels.count,
                  labels.allSatisfy({ !$0.isEmpty && $0.count <= 40 }) else {
                throw ZoeError("Classification needs 2–8 unique labels.")
            }
        }
        if kind == .select {
            guard !fields.isEmpty, fields.count <= 16, Set(fields).count == fields.count,
                  fields.allSatisfy({ !$0.isEmpty && !$0.split(separator: ".", omittingEmptySubsequences: false).contains("") }) else {
                throw ZoeError("Selection needs 1–16 unique, nonempty field paths.")
            }
        }
    }
}

struct RunBudget: Codable, Hashable, Sendable {
    var maxSteps = 500
    var maxModelCalls = 60
    var maxSeconds = 600
    func validate() throws {
        guard (1...1000).contains(maxSteps), (1...100).contains(maxModelCalls), (1...900).contains(maxSeconds) else {
            throw ZoeError("Invalid run budget.")
        }
    }
}

struct RunResult: Codable, Sendable {
    static let isolatedItemNote = "Some items were skipped. Results contain successful items only; see the run log."
    enum Status: String, Codable { case complete, partial, failed, needsUser, needsRebuild }
    var output: JSONValue = .null
    var status: Status = .complete
    var notes: [String] = []
    var log: [String] = []
    var sources: [URL] = []
    var date = Date.now
    /// Completed collections are evidence from an unfinished run, never a fabricated final answer.
    var completedCollections: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey { case output, status, notes, log, sources, date, completedCollections }
    init(output: JSONValue = .null, status: Status = .complete, notes: [String] = [], sources: [URL] = [], date: Date = .now,
         completedCollections: [String: JSONValue] = [:], log: [String] = []) {
        self.output = output; self.status = status; self.notes = notes; self.sources = sources; self.date = date
        self.completedCollections = completedCollections; self.log = log
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output = try c.decode(JSONValue.self, forKey: .output)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .complete
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        log = try c.decodeIfPresent([String].self, forKey: .log) ?? []
        sources = try c.decodeIfPresent([URL].self, forKey: .sources) ?? []
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .now
        completedCollections = try c.decodeIfPresent([String: JSONValue].self, forKey: .completedCollections) ?? [:]
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(output, forKey: .output); try c.encode(status, forKey: .status)
        try c.encode(notes, forKey: .notes); try c.encode(sources, forKey: .sources); try c.encode(date, forKey: .date)
        if !log.isEmpty { try c.encode(log, forKey: .log) }
        if !completedCollections.isEmpty { try c.encode(completedCollections, forKey: .completedCollections) }
    }
}

struct ZoeError: LocalizedError {
    let message: String
    var status: RunResult.Status = .failed
    var stopsRun = false
    init(_ message: String, status: RunResult.Status = .failed, stopsRun: Bool = false) {
        self.message = message; self.status = status; self.stopsRun = stopsRun
    }
    var errorDescription: String? { message }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e
    }
}
