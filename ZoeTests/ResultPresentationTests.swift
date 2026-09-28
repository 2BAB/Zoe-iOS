import Testing
@testable import Zoe

@MainActor
struct ResultPresentationTests {
    @Test(arguments: [0, 1, 3, 12])
    func finishedListsReportTheirActualCount(count: Int) {
        let result = RunResult(output: .array((0..<count).map { .number(Double($0)) }))
        #expect(AppModel.statusText(for: result) == "Run finished — \(count) records returned.")
    }

    @Test(arguments: [JSONValue.object(["items": .array([])]), .string("A summary"), .null])
    func otherOutputShapesDoNotInventRecordCounts(output: JSONValue) {
        #expect(AppModel.statusText(for: RunResult(output: output)) == "Run finished.")
    }

    @Test(arguments: [RunResult.Status.partial, .failed, .needsUser, .needsRebuild])
    func unfinishedEmptyRunsAreNotShownAsCompleted(status: RunResult.Status) {
        let result = RunResult(output: .array([]), status: status)
        let text = AppModel.statusText(for: result)
        #expect(text != "Run finished — 0 records returned.")
        #expect(text.contains("Check the notes."))
    }
}
