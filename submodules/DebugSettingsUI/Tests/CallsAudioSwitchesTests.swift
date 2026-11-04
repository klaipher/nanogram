import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The local-only call audio switches. Every one of them changes how this device processes or routes audio,
/// none alters what is negotiated or sent, and all stay off until the owner has compared them on a device.
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
        XCTAssertFalse(settings.callsAdvancedDucking)
        XCTAssertFalse(settings.callsGroupNarrowbandProcessing)
        XCTAssertFalse(settings.callsKeepSessionMode)
    }

    /// Advanced ducking first shipped on by default and every settings blob saved since holds `true` under its
    /// old key whether or not the user touched the switch. That value must not turn it on.
    func testDuckingSavedAsOnBeforeItWasMadeOptInStaysOff() throws {
        struct OldOnBlob: Encodable {
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: StringCodingKey.self)
                try container.encode(true, forKey: "callsAdvancedDucking")
            }
        }
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(OldOnBlob()))
        XCTAssertFalse(settings.callsAdvancedDucking)
    }

    func testSettingsFromBeforeTheSwitchesDecodeAsTheDefaults() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(EmptyBlob()))
        XCTAssertFalse(settings.callsSystemNoiseSuppression)
        XCTAssertFalse(settings.callsAdvancedDucking)
        XCTAssertFalse(settings.callsGroupNarrowbandProcessing)
        XCTAssertFalse(settings.callsKeepSessionMode)
    }

    func testSwitchesRoundTrip() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.callsSystemNoiseSuppression = true
        settings.callsAdvancedDucking = true
        settings.callsGroupNarrowbandProcessing = true
        settings.callsKeepSessionMode = true
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertTrue(decoded.callsSystemNoiseSuppression)
        XCTAssertTrue(decoded.callsAdvancedDucking)
        XCTAssertTrue(decoded.callsGroupNarrowbandProcessing)
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
        XCTAssertEqual(entries[index + 2].stableId, DebugControllerEntry.callsAdvancedDucking(false).stableId)
        XCTAssertEqual(entries[index + 3].stableId, DebugControllerEntry.callsGroupNarrowbandProcessing(false).stableId)
        XCTAssertEqual(entries[index + 4].stableId, DebugControllerEntry.callsKeepSessionMode(false).stableId)
    }
}
