import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The local-only call and live stream switches. All of them live in the one Debug Settings section
/// "Streams & Calls", and none changes what is negotiated or sent. Four start on and group noise suppression
/// starts as "RNNoise only" (owner decision, 2026-11); advanced ducking stays off. Bug fixes and low-risk wins have no switch any more, and the experiments the owner removed
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

    func testDefaultsAreTheOwnersChoice() {
        let settings = ExperimentalUISettings.defaultSettings
        XCTAssertTrue(settings.callsLivestreamHardwareDecoding)
        XCTAssertTrue(settings.callsNativeCapturePath)
        XCTAssertTrue(settings.callsSystemNoiseSuppression)
        XCTAssertTrue(settings.callsThermalVideoLadder)
        XCTAssertEqual(settings.callsGroupNoiseMode, 2)
        XCTAssertTrue(settings.callsAdvancedDucking)
    }

    func testSettingsFromBeforeTheSwitchesDecodeAsTheDefaults() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(EmptyBlob()))
        XCTAssertTrue(settings.callsLivestreamHardwareDecoding)
        XCTAssertTrue(settings.callsNativeCapturePath)
        XCTAssertTrue(settings.callsSystemNoiseSuppression)
        XCTAssertTrue(settings.callsThermalVideoLadder)
        XCTAssertEqual(settings.callsGroupNoiseMode, 2)
        XCTAssertTrue(settings.callsAdvancedDucking)
    }

    /// The whole struct is saved on every change, so an install that ever touched Debug Settings holds `false` (and
    /// group noise mode 0) under the old keys without having chosen them. Those values must not win over the new defaults.
    func testExplicitOldValuesFromBeforeTheDefaultsChangedAreIgnored() throws {
        struct OldOffBlob: Encodable {
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: StringCodingKey.self)
                try container.encode(false, forKey: "callsLivestreamHardwareDecoding")
                try container.encode(false, forKey: "callsNativeCapturePath")
                try container.encode(false, forKey: "callsSystemNoiseSuppression")
                try container.encode(false, forKey: "callsThermalVideoLadder")
                try container.encode(0 as Int32, forKey: "callsGroupNoiseMode")
            }
        }
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(OldOffBlob()))
        XCTAssertTrue(settings.callsLivestreamHardwareDecoding)
        XCTAssertTrue(settings.callsNativeCapturePath)
        XCTAssertTrue(settings.callsSystemNoiseSuppression)
        XCTAssertTrue(settings.callsThermalVideoLadder)
        XCTAssertEqual(settings.callsGroupNoiseMode, 2)
    }

    /// A choice made after the change is stored under the new keys and survives a save and a load, off included.
    func testAChoiceMadeAfterTheChangeIsKept() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.callsLivestreamHardwareDecoding = false
        settings.callsNativeCapturePath = false
        settings.callsSystemNoiseSuppression = false
        settings.callsThermalVideoLadder = false
        settings.callsGroupNoiseMode = 0
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertFalse(decoded.callsLivestreamHardwareDecoding)
        XCTAssertFalse(decoded.callsNativeCapturePath)
        XCTAssertFalse(decoded.callsSystemNoiseSuppression)
        XCTAssertFalse(decoded.callsThermalVideoLadder)
        XCTAssertEqual(decoded.callsGroupNoiseMode, 0)
    }

    /// Advanced ducking is on by default again (owner decision 2026-11-07). Blobs saved while it was opt-in hold `false`
    /// under "callsAdvancedDuckingOptIn" (and the first builds `true` under "callsAdvancedDucking") whether or not the user
    /// touched the switch; neither old key decides it.
    func testDuckingSavedUnderTheOldKeysFollowsTheNewDefault() throws {
        struct OldBlob: Encodable {
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: StringCodingKey.self)
                try container.encode(true, forKey: "callsAdvancedDucking")
                try container.encode(false, forKey: "callsAdvancedDuckingOptIn")
            }
        }
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(OldBlob()))
        XCTAssertTrue(settings.callsAdvancedDucking)
    }

    /// Switches that became always-on keep their keys in old blobs; reading such a blob must work and keep the
    /// stored values of the switches that remain.
    func testBlobsWithTheKeysOfRemovedSwitchesStillDecode() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(BlobWithRemovedSwitches()))
        XCTAssertTrue(settings.callsLivestreamHardwareDecoding)
        XCTAssertEqual(settings.callsGroupNoiseMode, 2)
    }

    func testSwitchesRoundTripAndDoNotDisturbEachOther() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.callsAdvancedDucking = false
        settings.callsGroupNoiseMode = 1
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertFalse(decoded.callsAdvancedDucking)
        XCTAssertEqual(decoded.callsGroupNoiseMode, 1)
        XCTAssertTrue(decoded.callsLivestreamHardwareDecoding)
        XCTAssertTrue(decoded.callsNativeCapturePath)
        XCTAssertTrue(decoded.callsSystemNoiseSuppression)
        XCTAssertTrue(decoded.callsThermalVideoLadder)
        var onlyOne = ExperimentalUISettings.defaultSettings
        onlyOne.callsLivestreamHardwareDecoding = false
        let decodedOne = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(onlyOne))
        XCTAssertFalse(decodedOne.callsLivestreamHardwareDecoding)
        XCTAssertTrue(decodedOne.callsNativeCapturePath)
        XCTAssertEqual(decodedOne.callsGroupNoiseMode, 2)
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
