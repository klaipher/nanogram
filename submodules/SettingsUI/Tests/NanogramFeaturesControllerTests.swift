import XCTest
import TelegramUIPreferences
@testable import SettingsUI

/// The user-facing switches that moved out of Debug Settings are offered on the Nanogram Features screen.
final class NanogramFeaturesControllerTests: XCTestCase {
    func testMovedSwitchesAreOnTheScreen() {
        let entries = nanogramFeaturesControllerEntries(features: .defaultSettings, experimental: .defaultSettings)
        var found = Set<String>()
        for entry in entries {
            switch entry {
            case .onDeviceTranscription: found.insert("transcription")
            case .callsSystemNoiseSuppression: found.insert("systemNoise")
            case .callsAdvancedDucking: found.insert("ducking")
            case .callsGroupNoiseMode: found.insert("groupNoise")
            case .callsThermalVideoLadder: found.insert("thermal")
            case .glanceables: found.insert("glanceables")
            default: break
            }
        }
        XCTAssertEqual(found, ["transcription", "systemNoise", "ducking", "groupNoise", "thermal", "glanceables"])
    }

    func testStableIdsAreUnique() {
        let entries = nanogramFeaturesControllerEntries(features: .defaultSettings, experimental: .defaultSettings)
        XCTAssertEqual(Set(entries.map { $0.stableId }).count, entries.count)
    }
}
