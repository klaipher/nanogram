import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The three local-only call video switches (livestream hardware decoding, native camera frames,
/// low-latency encoder) are off until the owner turns them on after an A/B on a device.
final class CallsVideoSwitchesTests: XCTestCase {
    private struct EmptyBlob: Encodable {
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(1 as Int32, forKey: "enableVoipTcp")
        }
    }

    func testSwitchesAreOffByDefault() {
        let settings = ExperimentalUISettings.defaultSettings
        XCTAssertFalse(settings.callsLivestreamHardwareDecoding)
        XCTAssertFalse(settings.callsNativeCapturePath)
        XCTAssertFalse(settings.callsEncoderLowLatency)
    }

    func testSettingsFromBeforeTheSwitchesDecodeAsOff() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(EmptyBlob()))
        XCTAssertFalse(settings.callsLivestreamHardwareDecoding)
        XCTAssertFalse(settings.callsNativeCapturePath)
        XCTAssertFalse(settings.callsEncoderLowLatency)
    }

    func testSwitchesRoundTrip() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.callsLivestreamHardwareDecoding = true
        settings.callsEncoderLowLatency = true
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertTrue(decoded.callsLivestreamHardwareDecoding)
        XCTAssertFalse(decoded.callsNativeCapturePath)
        XCTAssertTrue(decoded.callsEncoderLowLatency)
    }

    func testRowsFollowTheReferenceEngineRowInOrder() {
        let environment = DebugControllerEntriesEnvironment(isMainApp: true, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        let entries = debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: .defaultSettings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
        guard let index = entries.firstIndex(where: { $0.stableId == DebugControllerEntry.groupCallReferenceEngine(false).stableId }) else {
            XCTFail("no reference engine row")
            return
        }
        XCTAssertEqual(entries[index + 1].stableId, DebugControllerEntry.callsLivestreamHardwareDecoding(false).stableId)
        XCTAssertEqual(entries[index + 2].stableId, DebugControllerEntry.callsNativeCapturePath(false).stableId)
        XCTAssertEqual(entries[index + 3].stableId, DebugControllerEntry.callsEncoderLowLatency(false).stableId)
    }
}
