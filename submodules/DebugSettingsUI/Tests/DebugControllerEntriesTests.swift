import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// ItemList traps at runtime when its entries are not in strictly increasing order (section, then sort index),
/// so every stable id has to match the position its entry is appended at. Removing and adding Debug Settings rows
/// is where that goes wrong.
final class DebugControllerEntriesTests: XCTestCase {
    private func allSettings(_ on: Bool) -> ExperimentalUISettings {
        var settings = ExperimentalUISettings.defaultSettings
        settings.keepChatNavigationStack = on
        settings.skipReadHistory = on
        settings.alwaysDisplayTyping = on
        settings.crashOnLongQueries = on
        settings.enableVoipTcp = on
        settings.fakeGlass = on
        settings.compressedEmojiCache = on
        settings.localTranscription = on
        settings.disableQuickReaction = on
        settings.disableLanguageRecognition = on
        settings.disableImageContentAnalysis = on
        settings.crashOnMemoryPressure = on
        settings.groupCallReferenceEngine = on
        settings.liveStreamV2 = on
        settings.checkSerializedData = on
        settings.useInputDecEngine = on
        settings.forceListViewImplChatBackend = on
        settings.coreListScrollTrace = on
        settings.chatMediaEditorLegacy = on
        settings.mediaGridLegacy = on
        settings.sharedMediaGridLegacy = on
        settings.storyLegacyVideoWriter = on
        settings.chatLegacyVideoWriter = on
        settings.chatSideListLegacy = on
        settings.respectSystemMicrophone = on
        settings.springSendAnimation = on
        settings.fakeWalletTransfers = on
        settings.useModernVideoMessagePipeline = on ? nil : false
        settings.videoMessageCameraMode = on ? .hdLanczos : .legacy
        settings.videoMessageCloseFocus = on
        settings.videoMessageCameraMatrix = on ? .cameraTag : .bt709
        settings.stickerRendererMode = on ? .gpuAll : .cpu
        settings.tabletDisplayLinkFrameRateCap = on
        return settings
    }

    private func entries(isMainApp: Bool, isDevAccount: Bool, engineKind: String?, settings: ExperimentalUISettings) -> [DebugControllerEntry] {
        let environment = DebugControllerEntriesEnvironment(isMainApp: isMainApp, hasAccount: engineKind != nil, isDevAccount: isDevAccount, modernVideoMessagePipelineKilled: false, networkEngineKind: engineKind, useBetaFeatures: false)
        return debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: settings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
    }

    func testEntriesAreInStrictlyIncreasingOrder() {
        for isMainApp in [true, false] {
            for isDevAccount in [true, false] {
                for engineKind in [nil, "rust"] as [String?] {
                    for on in [true, false] {
                        let entries = self.entries(isMainApp: isMainApp, isDevAccount: isDevAccount, engineKind: engineKind, settings: self.allSettings(on))
                        XCTAssertFalse(entries.isEmpty)
                        for (lhs, rhs) in zip(entries, entries.dropFirst()) {
                            XCTAssertTrue(lhs < rhs, "\(lhs.stableId) before \(rhs.stableId) (main app \(isMainApp), dev \(isDevAccount))")
                        }
                        XCTAssertEqual(Set(entries.map(\.stableId)).count, entries.count)
                    }
                }
            }
        }
    }

    func testCircleCloseFocusSwitchFollowsTheVideoMessageCameraRow() {
        for isMainApp in [true, false] {
            let entries = self.entries(isMainApp: isMainApp, isDevAccount: false, engineKind: nil, settings: .defaultSettings)
            guard let index = entries.firstIndex(where: { $0.stableId == DebugControllerEntry.videoMessageCameraMode(.hdBilinear).stableId }) else {
                XCTFail("no Video Message Camera row")
                continue
            }
            XCTAssertTrue(index + 1 < entries.count)
            XCTAssertEqual(entries[index + 1].stableId, DebugControllerEntry.videoMessageCloseFocus(false).stableId)
        }
    }

    func testCircleColourDecodeRowFollowsTheCloseFocusSwitch() {
        for isMainApp in [true, false] {
            for on in [true, false] {
                let entries = self.entries(isMainApp: isMainApp, isDevAccount: false, engineKind: nil, settings: self.allSettings(on))
                guard let index = entries.firstIndex(where: { $0.stableId == DebugControllerEntry.videoMessageCloseFocus(false).stableId }) else {
                    XCTFail("no Circle Close Focus row")
                    continue
                }
                XCTAssertTrue(index + 1 < entries.count)
                let expected: DebugControllerEntry = .videoMessageCameraMatrix(on ? .cameraTag : .bt709)
                XCTAssertEqual(entries[index + 1].stableId, expected.stableId)
                guard case let .videoMessageCameraMatrix(value) = entries[index + 1] else {
                    XCTFail("Circle Colour Decode row missing")
                    continue
                }
                XCTAssertEqual(value, on ? .cameraTag : .bt709)
            }
        }
        let defaults = self.entries(isMainApp: true, isDevAccount: false, engineKind: nil, settings: .defaultSettings)
        XCTAssertTrue(defaults.contains(where: {
            if case .videoMessageCameraMatrix(.bt709) = $0 {
                return true
            }
            return false
        }))
    }

    func testCpuSavingSwitchesAreShown() {
        let ids = Set(self.entries(isMainApp: true, isDevAccount: false, engineKind: "mtproto", settings: .defaultSettings).map(\.stableId))
        for entry: DebugControllerEntry in [.disableImageContentAnalysis(false), .disableLanguageRecognition(false), .localTranscription(false), .enableVoipTcp(false), .forceListViewImplChatBackend(false)] {
            XCTAssertTrue(ids.contains(entry.stableId))
        }
    }
}

/// Settings stored by earlier builds carry keys for switches that no longer exist. They must decode, keeping every
/// value that still exists, or the user's other experimental settings would reset.
final class ExperimentalUISettingsCompatibilityTests: XCTestCase {
    private struct OldSettings: Encodable {
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(1 as Int32, forKey: "keepChatNavigationStack")
            try container.encode(1 as Int32, forKey: "chatListPhotos")
            try container.encode(1 as Int32, forKey: "knockoutWallpaper")
            try container.encode(1 as Int32, forKey: "enableVoipTcp")
            try container.encode(1 as Int32, forKey: "localTranscription")
            try container.encode(true, forKey: "enableReactionOverrides")
            try container.encode(true, forKey: "browserExperiment")
            try container.encode([Int32](), forKey: "accountReactionEffectOverrides")
            try container.encode(true, forKey: "disableImageContentAnalysis")
            try container.encode(true, forKey: "logLanguageRecognition")
            try container.encode(true, forKey: "storiesJpegExperiment")
            try container.encode(true, forKey: "crashOnMemoryPressure")
            try container.encode(true, forKey: "experimentalCallMute")
            try container.encode(true, forKey: "enableUpdates")
            try container.encode(true, forKey: "enablePWA")
            try container.encode(true, forKey: "forceClearGlass")
            try container.encode(true, forKey: "coreListChatBackend")
            try container.encode(true, forKey: "inputDecTextBackend")
            try container.encode(true, forKey: "forceRLottieBackend")
            try container.encode(false, forKey: "useModernVideoMessagePipeline")
            try container.encode("legacy", forKey: "videoMessageCameraMode")
            try container.encode("gpuLarge", forKey: "stickerRendererMode")
        }
    }

    func testOldBlobDecodesAndKeepsLiveValues() throws {
        let data = try EngineEncoder.encode(OldSettings())
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: data)
        XCTAssertTrue(settings.keepChatNavigationStack)
        XCTAssertTrue(settings.enableVoipTcp)
        XCTAssertTrue(settings.localTranscription)
        XCTAssertTrue(settings.disableImageContentAnalysis)
        XCTAssertTrue(settings.crashOnMemoryPressure)
        XCTAssertEqual(settings.useModernVideoMessagePipeline, false)
        XCTAssertEqual(settings.videoMessageCameraMode, .legacy)
        XCTAssertEqual(settings.stickerRendererMode, .gpuLarge)
        // The old "force CoreList on" switch does not turn into the new opt-out.
        XCTAssertFalse(settings.forceListViewImplChatBackend)
    }

    func testCircleCloseFocusIsOnByDefaultAndInOldBlobs() throws {
        XCTAssertTrue(ExperimentalUISettings.defaultSettings.videoMessageCloseFocus)
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(OldSettings()))
        XCTAssertTrue(settings.videoMessageCloseFocus)
    }

    private struct CloseFocusOffUnderOldKey: Encodable {
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(false, forKey: "videoMessageCloseFocus")
        }
    }

    // Every saved blob from before the default flipped stores `false` under the old key, whether or not the
    // user ever touched the switch, so that value is ignored and the switch turns on once for everyone.
    func testCircleCloseFocusTurnsOnOnceForSettingsSavedWhileItWasOffByDefault() throws {
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(CloseFocusOffUnderOldKey()))
        XCTAssertTrue(settings.videoMessageCloseFocus)
    }

    func testCircleCloseFocusTurnedOffAfterTheFlipStaysOff() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.videoMessageCloseFocus = false
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertFalse(decoded.videoMessageCloseFocus)
    }

    func testCircleColourDecodeDefaultsToBT709AndInOldBlobs() throws {
        XCTAssertEqual(ExperimentalUISettings.defaultSettings.videoMessageCameraMatrix, .bt709)
        let settings = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(OldSettings()))
        XCTAssertEqual(settings.videoMessageCameraMatrix, .bt709)
    }

    func testRoundTrip() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.forceListViewImplChatBackend = true
        settings.enableVoipTcp = true
        settings.videoMessageCloseFocus = false
        settings.videoMessageCameraMatrix = .cameraTag
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}
