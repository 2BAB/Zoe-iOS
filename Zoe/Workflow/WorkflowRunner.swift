import Foundation

@MainActor
protocol SemanticProcessing {
    func evaluate(_ task: SemanticTask, input: JSONValue, meter: RunMeter) async throws -> JSONValue
}

@MainActor
final class RunMeter {
    let budget: RunBudget
    let started = ContinuousClock.now
    private(set) var calls = 0
    private var steps = 0
    private var invalidated = false
    var notes: [String] = []
    private(set) var log: [String] = []
    private let report: (String) -> Void
    var currentSemanticPath = "semantic"
    init(_ budget: RunBudget, log: @escaping (String) -> Void = { _ in }) {
        self.budget = budget; self.report = log
    }
    func check() throws {
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        guard started.duration(to: .now) < .seconds(budget.maxSeconds) else {
            throw ZoeError("Run time budget reached.", status: .partial)
        }
    }
    func step() throws {
        try check(); steps += 1
        guard steps <= budget.maxSteps else { throw ZoeError("Step budget reached.", status: .partial) }
    }
    func modelCall() throws {
        try check(); calls += 1
        guard calls <= budget.maxModelCalls else { throw ZoeError("Model-call budget reached.", status: .partial) }
    }
    func partial(_ note: String) { if !notes.contains(note) { notes.append(note) } }
    func itemFailed(path: String, error: any Error) {
        let message = "Skipped \(path): \(error.localizedDescription)"
        log.append(message); report(message)
        partial(RunResult.isolatedItemNote)
    }
    func canIsolate(_ error: any Error) -> Bool {
        guard !(error is CancellationError), !Task.isCancelled, !invalidated,
              started.duration(to: .now) < .seconds(budget.maxSeconds),
              steps <= budget.maxSteps, calls <= budget.maxModelCalls else { return false }
        if let error = error as? ZoeError,
           error.status == .needsUser || error.status == .partial || error.stopsRun { return false }
        return true
    }
    func invalidate() { invalidated = true }
}

@MainActor
struct WorkflowRunner {
    let browser: any Browsing
    var model: any SemanticProcessing = OnDeviceModel()
    var log: (String) -> Void = { _ in }

    func run(_ workflow: Workflow) async throws -> RunResult {
        try workflow.validate()
        let meter = RunMeter(workflow.budget, log: log)
        let context = Context(variables: workflow.parameters)
        let now = Date.now
        let formatter = ISO8601DateFormatter()
        context.variables["run"] = .object(["date": .string(formatter.string(from: now)),
                                            "timeZone": .string(TimeZone.current.identifier)])
        do {
            return try await withTimeout(seconds: workflow.budget.maxSeconds, onCancel: {
                meter.invalidate()
                self.browser.stop()
            }) {
                try await self.browser.start(at: workflow.startURL, allowedHosts: workflow.hosts)
                try meter.check()
                try await self.execute(workflow.steps, context: context, meter: meter)
                let output = try ValueRef.variable(workflow.output).resolve(in: context.variables)
                return RunResult(output: output, status: meter.notes.isEmpty ? .complete : .partial,
                                 notes: meter.notes, sources: self.browser.sources, date: now, log: meter.log)
            }
        } catch {
            browser.stop()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failureStatus = (error as? ZoeError)?.status ?? .failed
            return RunResult(output: (try? ValueRef.variable(workflow.output).resolve(in: context.variables)) ?? .null,
                             status: !meter.log.isEmpty && failureStatus == .failed ? .partial : failureStatus,
                             notes: meter.notes + [error.localizedDescription], sources: browser.sources, date: now,
                             completedCollections: context.progress.collections, log: meter.log)
        }
    }

    private final class Context {
        var variables: [String: JSONValue]
        let progress: Progress
        let scope: String
        init(variables: [String: JSONValue], progress: Progress = Progress(), scope: String = "") {
            self.variables = variables; self.progress = progress; self.scope = scope
        }
        func checkpoint(_ name: String, _ values: [JSONValue]) {
            progress.collections[scope + name] = .array(values)
        }
    }
    private final class Progress { var collections: [String: JSONValue] = [:] }

    private func execute(_ steps: [Step], context: Context, meter: RunMeter) async throws {
        for step in steps {
            try meter.step()
            log("Started: \(step.title)")
            switch step {
            case .act(let action): try await browser.act(action, variables: context.variables)
            case .read(let output, let script, let inputs):
                let value = try await browser.read(script, inputs: inputs.mapValues { try $0.resolve(in: context.variables) })
                try meter.check()
                context.variables[output] = value
            case .semantic(let output, let input, let task):
                meter.currentSemanticPath = context.scope + output
                let value = try await model.evaluate(task, input: input.resolve(in: context.variables), meter: meter)
                try meter.check()
                context.variables[output] = value
            case .forEach(let input, let item, let children, let collect, let output, let limit):
                guard let values = try input.resolve(in: context.variables).array else { throw ZoeError("forEach requires an array.") }
                if values.count > limit { meter.partial("Only \(limit) of \(values.count) records processed.") }
                let outer = context.variables
                var results: [JSONValue] = []
                context.variables[output] = .array([])
                for (index, value) in values.prefix(limit).enumerated() {
                    let local = Context(variables: outer, progress: context.progress,
                                        scope: "\(context.scope)\(output)[\(index)].")
                    local.variables[item] = value
                    do {
                        try await execute(children, context: local, meter: meter)
                        results.append(try collect.resolve(in: local.variables))
                        context.variables[output] = .array(results)
                        context.checkpoint(output, results)
                    } catch {
                        guard meter.canIsolate(error) else { throw error }
                        meter.itemFailed(path: "\(context.scope)\(output)[\(index)]", error: error)
                    }
                }
            }
            try meter.check()
        }
    }
}
