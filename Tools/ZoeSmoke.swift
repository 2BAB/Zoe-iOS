import AppKit
import Foundation
import FoundationModels

/// Opt-in live integration driver. Never logs the API key.
@main
struct ZoeSmoke {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        let browser = Browser()
        var lines: [String] = []
        let log: (String) -> Void = { line in lines.append(line); print(line); fflush(nil) }
        let runner = WorkflowRunner(browser: browser, model: OnDeviceModel(log: log), log: log)
        do {
            guard let command = args.first else { throw ZoeError("Usage: inspect URL [selector] | run workflow.json output-dir | build URL goal output-dir | build-offline-hn output-dir [feedback.json] | run-offline-hn workflow.json output-dir | model output-dir | cancel-model output-dir") }
            switch command {
            case "inspect":
                guard args.count >= 2, let url = URL(string: args[1]) else { throw ZoeError("Missing URL") }
                try await browser.start(at: url, allowedHosts: [])
                if args.count > 3 {
                    do { try await browser.act(.init(kind: .wait, wait: .init(script: args[3], timeoutSeconds: 20)), variables: [:]) }
                    catch { print("WAIT: \(error.localizedDescription)") }
                }
                print(try await browser.outline(of: args.count > 2 ? args[2] : "body"))
            case "run":
                guard args.count == 3 else { throw ZoeError("run needs workflow file and output folder") }
                let workflow = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: URL(filePath: args[1])))
                let result = try await runner.run(workflow)
                try save(result, "result.json", in: args[2])
                try save(workflow, "workflow.json", in: args[2])
                try save(lines, "log.json", in: args[2])
                print("RESULT: \(result.status.rawValue) \(result.notes)")
                if result.status != .complete { exit(2) }
            case "build":
                guard (4...5).contains(args.count), let url = URL(string: args[1]) else { throw ZoeError("build needs URL, goal, output folder and optional validation feedback") }
                let env = ProcessInfo.processInfo.environment
                guard let key = env["GEMINI_API_KEY"], !key.isEmpty else { throw ZoeError("GEMINI_API_KEY not set") }
                let workflow = try await WorkflowBuilder.build(goal: args[2], startURL: url,
                    model: GeminiLanguageModel(apiKey: key, model: env["GEMINI_MODEL"] ?? "gemini-3.8-flash"),
                    runner: runner,
                    validationFeedback: args.count == 5 ? try String(contentsOfFile: args[4], encoding: .utf8) : nil,
                    log: log)
                try save(workflow, "workflow.json", in: args[3])
                let replay = try await runner.run(workflow)
                try save(replay, "result.json", in: args[3])
                try save(lines, "log.json", in: args[3])
                print("BUILT + INDEPENDENT REPLAY: \(replay.status.rawValue) \(replay.notes)")
                if !replay.builderVerificationAccepted { exit(2) }
            case "run-offline-hn":
                guard args.count == 3 else { throw ZoeError("run-offline-hn needs workflow file and output folder") }
                guard SystemLanguageModel.default.variant == .core3 else { throw ZoeError("Requires actual Core.") }
                var workflow = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: URL(filePath: args[1])))
                // Substitute only the network boundary, not scripts, semantic instructions or limits.
                workflow.startURL = OfflineHN.startURL
                workflow.allowedHosts = [OfflineHN.startURL.host()!]
                let fixture = OfflineHN()
                let localRunner = WorkflowRunner(browser: fixture, model: OnDeviceModel(log: log), log: log)
                let result = try await localRunner.run(workflow)
                try save(result, "result.json", in: args[2])
                try save(workflow, "workflow.json", in: args[2])
                try save(lines, "log.json", in: args[2])
                guard result.status == .complete else { throw ZoeError("Offline preset replay did not complete.") }
                try fixture.verifyScopeAndFacts(result)
                print("OFFLINE PRESET: real Core/WebKit replay passed scope, source and sentiment checks.")
            case "build-offline-hn":
                guard (2...3).contains(args.count) else { throw ZoeError("build-offline-hn needs output folder and optional validation-feedback.json") }
                guard SystemLanguageModel.default.variant == .core3 else { throw ZoeError("Requires actual Core.") }
                let env = ProcessInfo.processInfo.environment
                guard let key = env["GEMINI_API_KEY"], !key.isEmpty else { throw ZoeError("GEMINI_API_KEY not set") }
                let fixture = OfflineHN()
                let localRunner = WorkflowRunner(browser: fixture, model: OnDeviceModel(log: log), log: log)
                let workflow = try await WorkflowBuilder.build(
                    goal: "Find up to three Apple stories on the Hacker News front page, and judge whether the first three comments on each are optimistic, pessimistic, or neutral.",
                    startURL: OfflineHN.startURL,
                    model: GeminiLanguageModel(apiKey: key, model: env["GEMINI_MODEL"] ?? "gemini-3.8-flash"),
                    runner: localRunner,
                    validationFeedback: args.count == 3 ? try String(contentsOfFile: args[2], encoding: .utf8) : nil,
                    log: log)
                try save(workflow, "workflow.json", in: args[1])
                let result = try await localRunner.run(workflow)
                try save(result, "result.json", in: args[1])
                try save(lines, "log.json", in: args[1])
                guard result.status == .complete else { throw ZoeError("Independent offline replay did not complete.") }
                try fixture.verifyScopeAndFacts(result)
                print("OFFLINE HN: remote-generated workflow + independent real Core/WebKit replay passed scope, source and sentiment checks.")
            case "model":
                guard args.count == 2 else { throw ZoeError("model needs output folder") }
                let model = SystemLanguageModel.default
                print("MODEL: \(model.variant.displayName), \(model.contextSize) tokens, \(model.availability)")
                guard model.variant == .core3 else { throw ZoeError("This test requires actual Core, not Advanced.") }
                let processor = OnDeviceModel(log: log)
                let hnURL = URL(filePath: "Zoe/Resources/hn-ai-watch.json")
                let hn = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: hnURL))
                guard var selectionTask = semanticTasks(in: hn.steps).first(where: { $0.kind == .select }) else {
                    throw ZoeError("HN selection step missing")
                }
                // Test the actual packing path with long evidence, not a characters/token estimate.
                let longItems: [JSONValue] = (0..<8).map { index in .object([
                    "title": .string("Record \(index). " + String(repeating: "Detailed evidence about an operating system update. ", count: 35))
                ]) }
                let packed = try await processor.packSelectionBatch(selectionTask, items: longItems[...])
                guard try await processor.fits(packed.request),
                      packed.records[0].object?["data"] == longItems[0] else {
                    throw ZoeError("Token packing lost data or exceeded budget.")
                }
                if packed.records.count < min(longItems.count, OnDeviceModel.maximumBatchRecords) {
                    let larger = try await processor.prepareSelectionBatch(selectionTask,
                        items: Array(longItems.prefix(packed.records.count + 1)))
                    guard try await !processor.fits(larger.request) else {
                        throw ZoeError("Packing did not use the largest fitting prefix.")
                    }
                }
                let oversizedMeter = RunMeter(RunBudget())
                let oversizedRecord = JSONValue.object([
                    "title": .string(String(repeating: "Unrelated evidence. ", count: 2500))
                ])
                let oversizedSelection = try await processor.evaluate(selectionTask,
                    input: .array([oversizedRecord]), meter: oversizedMeter)
                guard oversizedSelection == .array([]), oversizedMeter.calls == 0,
                      oversizedMeter.log.count == 1 else {
                    throw ZoeError("Oversized evidence was not skipped and logged.")
                }
                try save(["longRecordsPacked": packed.records.count, "oversizedInferenceCalls": oversizedMeter.calls,
                          "oversizedFailures": oversizedMeter.log.count],
                         "token-budget-evaluation.json", in: args[1])
                guard let task = semanticTasks(in: hn.steps).first(where: { $0.kind == .classify }) else {
                    throw ZoeError("HN classification task missing.")
                }
                let cases: [(String, String)] = [
                    ("I love this improvement. Apple's future looks bright!", "optimistic"),
                    ("This is a disaster. I expect Apple's quality to keep getting worse.", "pessimistic"),
                    ("The article says the update will be released on Tuesday.", "neutral"),
                    ("这次改进很棒，我对苹果的未来非常乐观。", "optimistic"),
                    ("又是倒退。我对苹果接下来的产品很悲观。", "pessimistic"),
                    ("发布会定于周二上午十点开始。", "neutral")
                ]
                var records: [[String: String]] = []
                for (index, item) in cases.enumerated() {
                    let (input, expected) = item
                    let modelInput = JSONValue.object(["commentId": .string(String(index)), "text": .string(input)])
                    do {
                        let result = try await processor.evaluate(task, input: modelInput, meter: RunMeter(RunBudget()))
                        records.append(["input": input, "expected": expected, "actual": result.text])
                    } catch {
                        records.append(["input": input, "expected": expected, "error": error.localizedDescription])
                    }
                }
                let titles = ["Flip Fluid on Flip Dots", "Fifteen years later, the Apple Cards origin story",
                              "Bob Mackie dressed stars–if they were brave enough", "Apple releases a new iPhone",
                              "Apple harvest grows this year", "Go Concurrency Distilled"]
                let candidates = JSONValue.array(titles.map { .object(["title": .string($0)]) })
                selectionTask.limit = 6
                let selection = try await processor.evaluate(selectionTask, input: candidates, meter: RunMeter(RunBudget()))
                try save(selection, "selection-evaluation.json", in: args[1])
                let expectedTitles = [titles[1], titles[3]]
                let relevancePassed = selection.array?.compactMap({ $0.object?["title"]?.text }) == expectedTitles
                try save(records, "model-evaluation.json", in: args[1])
                try save(lines, "log.json", in: args[1])
                let sentimentMatches = records.filter { $0["actual"] == $0["expected"] }.count
                let labeled = OfflineHN.selectionCases
                // One front page of 30 distinct titles; this is a labeled smoke set, not a production benchmark.
                let inputs = labeled.enumerated().map { index, entry in
                    JSONValue.object(["id": .string(String(index)), "title": .string(entry.0)])
                }
                let expectedIDs = labeled.enumerated().filter { $0.element.1 }.map { String($0.offset) }
                let meter = RunMeter(RunBudget())
                let started = ContinuousClock.now
                selectionTask.limit = 30
                let batch = try await processor.packSelectionBatch(selectionTask, items: inputs[...])
                guard batch.records.count == 10 else { throw ZoeError("Short-title batch did not use the ten-record cap.") }
                let matches = try await processor.evaluate(selectionTask, input: .array(inputs), meter: meter)
                let actualIDs = matches.array?.compactMap { $0.object?["id"]?.text } ?? []
                try save(inputs, "batch-inputs.json", in: args[1])
                try save(["expected": expectedIDs, "actual": actualIDs], "batch-evaluation.json", in: args[1])
                try save(["calls": String(meter.calls), "duration": String(describing: started.duration(to: .now)),
                          "notes": meter.notes.joined(separator: "; ")], "batch-metrics.json", in: args[1])
                // Additional titles not used when designing the original 30-record regression set.
                let additional: [(String, Bool)] = [
                    ("AirPods Pro receive a firmware update", true),
                    ("Rust developers discuss embedded systems", false),
                    ("Apple TV+ orders a new science fiction series", true),
                    ("Amazon announces a new Kindle reader", false),
                    ("Apple Vision Pro developers preview spatial apps", true),
                    ("Valve improves Steam Deck battery life", false),
                    ("Apple silicon chips improve laptop efficiency", true),
                    ("Taylor Swift releases another album", false),
                    ("Apple Pay adds support for another bank", true),
                    ("Firefox on Linux gets a performance update", false),
                    ("Apple announces the schedule for WWDC", true),
                    ("Meta announces a new Quest headset", false)
                ]
                let additionalInput = JSONValue.array(additional.enumerated().map {
                    .object(["id": .string(String($0.offset)), "title": .string($0.element.0)])
                })
                let additionalMeter = RunMeter(RunBudget())
                let additionalOutput = try await processor.evaluate(selectionTask, input: additionalInput, meter: additionalMeter)
                let additionalActual = additionalOutput.array?.compactMap { $0.object?["id"]?.text } ?? []
                let additionalExpected = additional.enumerated().filter { $0.element.1 }.map { String($0.offset) }
                try save(additionalInput, "additional-inputs.json", in: args[1])
                try save(["actual": additionalActual, "expected": additionalExpected, "notes": additionalMeter.notes],
                         "additional-evaluation.json", in: args[1])
                try save(lines, "log.json", in: args[1])
                guard meter.notes.isEmpty, meter.calls == 3, additionalMeter.notes.isEmpty else {
                    throw ZoeError("Short-title batching failed; inspect batch-metrics.json and additional-evaluation.json.")
                }
                let pageHits = Set(actualIDs).intersection(Set(expectedIDs)).count
                let extraPicks = Set(actualIDs).subtracting(Set(expectedIDs)).count
                let probeHits = Set(additionalActual).intersection(Set(additionalExpected)).count
                print("BATCH: 30 titles in ten-record slices, \(meter.calls) model calls; \(pageHits)/\(expectedIDs.count) labeled matches, \(extraPicks) extra picks.")
                print("MODEL EVALUATION: \(sentimentMatches)/\(records.count) comment labels, 6-title probe exact: \(relevancePassed), 12-title probe: \(probeHits)/\(additionalExpected.count). Not a general accuracy guarantee.")
            case "cancel-model":
                guard args.count == 2 else { throw ZoeError("cancel-model needs output folder") }
                let processor = OnDeviceModel(log: log)
                let cancellationMeter = RunMeter(RunBudget())
                let inference = Task {
                    try await processor.evaluate(.init(kind: .summarize, instruction: "Summarize the engineering tradeoffs."),
                        input: .string(String(repeating: "An application can batch independent inputs to reduce inference calls, but must retain source identity and verify quality. ", count: 30)),
                        meter: cancellationMeter)
                }
                defer { inference.cancel() }
                try await withTimeout(seconds: 10) {
                    while cancellationMeter.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
                }
                // Wait for the response API rather than accidentally cancelling token counting.
                try await Task.sleep(for: .milliseconds(100))
                let started = ContinuousClock.now
                inference.cancel()
                do {
                    _ = try await withTimeout(seconds: 2) { try await inference.value }
                    throw ZoeError("The request finished before cancellation; this run did not test the cancel path.")
                } catch is CancellationError {
                    log("AFM cancellation returned after \(started.duration(to: .now)); model call had started.")
                }
                let after = try await processor.evaluate(.init(kind: .classify,
                    instruction: "Classify the outlook.", labels: ["optimistic", "pessimistic", "neutral"]),
                    input: .string("I am optimistic about the future!"), meter: RunMeter(RunBudget()))
                guard after == .string("optimistic") else { throw ZoeError("Model did not recover after cancellation.") }
                try save(lines, "log.json", in: args[1])
                print("CANCEL: cancellation returned; a fresh AFM session succeeded.")
            default: throw ZoeError("Unknown command")
            }
            browser.stop()
        } catch {
            browser.stop()
            let outputFolder: String?
            if args.first == "build", args.count >= 4 { outputFolder = args[3] }
            else if args.first == "build-offline-hn", args.count >= 2 { outputFolder = args[1] }
            else { outputFolder = args.last }
            if let folder = outputFolder, ["run", "build", "build-offline-hn", "run-offline-hn", "model", "cancel-model"].contains(args.first ?? "") {
                try? save(lines + ["ERROR: \(error.localizedDescription)"], "log.json", in: folder)
            }
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func semanticTasks(in steps: [Step]) -> [SemanticTask] {
        steps.flatMap { step -> [SemanticTask] in
            return switch step {
            case .semantic(_, _, let task): [task]
            case .forEach(_, _, let nested, _, _, _): semanticTasks(in: nested)
            default: []
            }
        }
    }

    static func save<T: Encodable>(_ value: T, _ name: String, in directory: String) throws {
        let folder = URL(filePath: directory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(value).write(to: folder.appending(path: name), options: .atomic)
    }
}
