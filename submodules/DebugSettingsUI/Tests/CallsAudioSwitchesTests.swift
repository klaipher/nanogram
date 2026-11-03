import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The local-only call audio switches. Two change how the system voice-processing unit and the 1:1 encoder are
/// configured and default to on (they cannot alter what is negotiated or sent); the other two replace parts of
/// the processing chain and stay off until the owner has compared them on a device.
final class CallsAudioSwitchesTests: XCTestCase {
    private struct EmptyBlob: Encodable {
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(1 as Int32, forKey: "enableVoipTcp")
        }
    }

    func testDefaults() {
        let settings = ExperimentalUISettings.defaultSettings
        XCTAssertFalse(settings.callsSystemNoiseSuppression)
        XCTAssertTrue(settings.callsAdvancedDucking)
        XCTAssertTrue(settings.callsOpusFirstLossFloor)
        XCTAssertFalse(settings.callsKeepSessionMode)
    }

    func testSettingsFromBeforeTheSwitchesDecodeAsTheDefaults() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(EmptyBlob()))
        XCTAssertFalse(settings.callsSystemNoiseSuppression)
        XCTAssertTrue(settings.callsAdvancedDucking)
        XCTAssertTrue(settings.callsOpusFirstLossFloor)
        XCTAssertFalse(settings.callsKeepSessionMode)
    }

    func testSwitchesRoundTripIncludingAUserTurningADefaultOnSwitchOff() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.callsSystemNoiseSuppression = true
        settings.callsAdvancedDucking = false
        settings.callsOpusFirstLossFloor = false
        settings.callsKeepSessionMode = true
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertTrue(decoded.callsSystemNoiseSuppression)
        XCTAssertFalse(decoded.callsAdvancedDucking)
        XCTAssertFalse(decoded.callsOpusFirstLossFloor)
        XCTAssertTrue(decoded.callsKeepSessionMode)
    }

    func testVideoSwitchesSurviveAnAudioSwitchChange() throws {
        // The call switches live in one blob: a regression in the shared encode/decode block would drop them.
        var settings = ExperimentalUISettings.defaultSettings
        settings.callsLivestreamHardwareDecoding = true
        settings.callsKeepSessionMode = true
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertTrue(decoded.callsLivestreamHardwareDecoding)
        XCTAssertTrue(decoded.callsKeepSessionMode)
    }

    func testRowsFollowTheVideoRowsInOrder() {
        let environment = DebugControllerEntriesEnvironment(isMainApp: true, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        let entries = debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: .defaultSettings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
        guard let index = entries.firstIndex(where: { $0.stableId == DebugControllerEntry.callsEncoderLowLatency(false).stableId }) else {
            XCTFail("no low-latency encoder row")
            return
        }
        XCTAssertEqual(entries[index + 1].stableId, DebugControllerEntry.callsSystemNoiseSuppression(false).stableId)
        XCTAssertEqual(entries[index + 2].stableId, DebugControllerEntry.callsAdvancedDucking(true).stableId)
        XCTAssertEqual(entries[index + 3].stableId, DebugControllerEntry.callsOpusFirstLossFloor(true).stableId)
        XCTAssertEqual(entries[index + 4].stableId, DebugControllerEntry.callsKeepSessionMode(false).stableId)
    }
}
