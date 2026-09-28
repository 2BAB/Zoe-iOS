import Foundation
import Testing
@testable import Zoe

struct PresetTests {
    @Test(arguments: VerifiedPreset.allCases)
    @MainActor
    func bundledPresetLoadsAndValidates(preset: VerifiedPreset) throws {
        let url = try #require(Bundle.main.url(forResource: preset.rawValue, withExtension: "json"))
        let workflow = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: url))
        try workflow.validate()
        #expect(!workflow.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
