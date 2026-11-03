import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The local-only call power switches: engine thread quality of service, the thermal video ladder and the
/// background video drop. All start off; none changes what is negotiated or sent to the peer.
final class CallsPowerSwitchesTests: XCTestCase {
    private struct EmptyBlob: Encodable {
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(1 as Int32, forKey: "enableVoipTcp")
        }
    }

    func testDefaultsAreOff() {
        let settings = ExperimentalUISettings.defaultSettings
        XCTAssertFalse(settings.callsThreadQoS)
        XCTAssertFalse(settings.callsThermalVideoLadder)
        XCTAssertFalse(settings.callsBackgroundVideoDrop)
    }

    func testSettingsFromBeforeTheSwitchesDecodeAsOff() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(EmptyBlob()))
        XCTAssertFalse(settings.callsThreadQoS)
        XCTAssertFalse(settings.callsThermalVideoLadder)
        XCTAssertFalse(settings.callsBackgroundVideoDrop)
    }

    func testSwitchesRoundTripAndDoNotDisturbTheOtherCallSwitches() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.callsThreadQoS = true
        settings.callsThermalVideoLadder = true
        settings.callsBackgroundVideoDrop = true
        settings.callsKeepSessionMode = true
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertTrue(decoded.callsThreadQoS)
        XCTAssertTrue(decoded.callsThermalVideoLadder)
        XCTAssertTrue(decoded.callsBackgroundVideoDrop)
        XCTAssertTrue(decoded.callsKeepSessionMode)
        XCTAssertFalse(decoded.callsSystemNoiseSuppression)
    }

    func testRowsFollowTheDisplayLinkRowInOrder() {
        let environment = DebugControllerEntriesEnvironment(isMainApp: true, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        let entries = debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: .defaultSettings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
        guard let index = entries.firstIndex(where: { $0.stableId == DebugControllerEntry.callsThreadQoS(false).stableId }) else {
            XCTFail("no thread quality of service row")
            return
        }
        XCTAssertEqual(entries[index + 1].stableId, DebugControllerEntry.callsThermalVideoLadder(false).stableId)
        XCTAssertEqual(entries[index + 2].stableId, DebugControllerEntry.callsBackgroundVideoDrop(false).stableId)
    }
}
