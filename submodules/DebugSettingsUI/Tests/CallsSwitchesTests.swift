import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The local-only call and live stream switches. All of them live in the one Debug Settings section
/// "Streams & Calls", all start off (group noise suppression starts as "both"), and none changes what is
/// negotiated or sent. Bug fixes and low-risk wins have no switch any more, and the experiments the owner removed
/// (thread priorities, keeping the videoChat audio session mode) are gone with their old behaviour: their old keys
/// are just ignored.
final class CallsSwitchesTests: XCTestCase {
    private struct EmptyBlob: Encodable {
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(1 as Int32, forKey: "enableVoipTcp")
        }
    }

    private struct BlobWithRemovedSwitches: Encodable {
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(true, forKey: "callsEncoderLowLatency")
            try container.encode(true, forKey: "callsGroupNarrowbandProcessing")
            try container.encode(true, forKey: "callsKeepSessionMode")
            try container.encode(true, forKey: "callsBackgroundVideoDrop")
            try container.encode(true, forKey: "callsThreadQoS")
            try container.encode(true, forKey: "callsLivestreamHardwareDecoding")
        }
    }

    private func entries() -> [DebugControllerEntry] {
        let environment = DebugControllerEntriesEnvironment(isMainApp: true, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        return debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: .defaultSettings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
    }

    func testSwitchesAreOffByDefault() {
        let settings = ExperimentalUISettings.defaultSettings
        XCTAssertFalse(settings.callsLivestreamHardwareDecoding)
        XCTAssertFalse(settings.callsNativeCapturePath)
        XCTAssertFalse(settings.callsSystemNoiseSuppression)
        XCTAssertFalse(settings.callsAdvancedDucking)
        XCTAssertFalse(settings.callsThermalVideoLadder)
        XCTAssertEqual(settings.callsGroupNoiseMode, 0)
    }

    func testSettingsFromBeforeTheSwitchesDecodeAsTheDefaults() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(EmptyBlob()))
        XCTAssertFalse(settings.callsLivestreamHardwareDecoding)
        XCTAssertEqual(settings.callsGroupNoiseMode, 0)
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

    /// Switches that became always-on keep their keys in old blobs; reading such a blob must work and keep the
    /// stored values of the switches that remain.
    func testBlobsWithTheKeysOfRemovedSwitchesStillDecode() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(BlobWithRemovedSwitches()))
        XCTAssertTrue(settings.callsLivestreamHardwareDecoding)
    }

    func testSwitchesRoundTripAndDoNotDisturbEachOther() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.callsLivestreamHardwareDecoding = true
        settings.callsNativeCapturePath = true
        settings.callsSystemNoiseSuppression = true
        settings.callsAdvancedDucking = true
        settings.callsThermalVideoLadder = true
        settings.callsGroupNoiseMode = 2
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertTrue(decoded.callsLivestreamHardwareDecoding)
        XCTAssertTrue(decoded.callsNativeCapturePath)
        XCTAssertTrue(decoded.callsSystemNoiseSuppression)
        XCTAssertTrue(decoded.callsAdvancedDucking)
        XCTAssertTrue(decoded.callsThermalVideoLadder)
        XCTAssertEqual(decoded.callsGroupNoiseMode, 2)
        var onlyOne = ExperimentalUISettings.defaultSettings
        onlyOne.callsGroupNoiseMode = 1
        let decodedOne = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(onlyOne))
        XCTAssertFalse(decodedOne.callsLivestreamHardwareDecoding)
        XCTAssertEqual(decodedOne.callsGroupNoiseMode, 1)
    }

    /// Every call and stream switch sits in its own section, behind its header, in this order, and none is left in
    /// the general experiments section.
    func testAllCallSwitchesAreInOneSectionBehindTheirHeader() {
        let expected: [DebugControllerEntry] = [
            .callsHeader(defaultPresentationTheme),
            .callsLivestreamHardwareDecoding(false),
            .callsNativeCapturePath(false),
            .callsSystemNoiseSuppression(false),
            .callsAdvancedDucking(false),
            .callsGroupNoiseMode(0),
            .callsThermalVideoLadder(false)
        ]
        let all = self.entries()
        guard let start = all.firstIndex(where: { $0.stableId == expected[0].stableId && $0.section == expected[0].section }) else {
            XCTFail("no Streams & Calls header")
            return
        }
        XCTAssertEqual(Array(all[start ..< start + expected.count]).map { $0.stableId }, expected.map { $0.stableId })
        let callsSection = expected[0].section
        for entry in expected {
            XCTAssertEqual(entry.section, callsSection)
        }
        XCTAssertEqual(all.filter { $0.section == callsSection }.count, expected.count)
        XCTAssertNotEqual(callsSection, DebugControllerEntry.experimentsHeader(defaultPresentationTheme).section)
        XCTAssertGreaterThan(callsSection, DebugControllerEntry.experimentsHeader(defaultPresentationTheme).section)
    }

    func testTheSectionComesAfterExperimentsInTheList() {
        let all = self.entries()
        let sections = all.map { $0.section }
        XCTAssertEqual(sections, sections.sorted())
        for (index, entry) in all.enumerated().dropFirst() where all[index - 1].section == entry.section {
            XCTAssertTrue(all[index - 1] < entry)
        }
    }
}
