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
        settings.forceRLottieBackend = on
        settings.respectSystemMicrophone = on
        settings.springSendAnimation = on
        settings.fakeWalletTransfers = on
        settings.useModernVideoMessagePipeline = on ? nil : false
        settings.videoMessageCameraMode = on ? .hdLanczos : .legacy
        settings.stickerRendererMode = on ? .gpuAll : .cpu
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
        XCTAssertTrue(settings.forceRLottieBackend)
        XCTAssertEqual(settings.useModernVideoMessagePipeline, false)
        XCTAssertEqual(settings.videoMessageCameraMode, .legacy)
        XCTAssertEqual(settings.stickerRendererMode, .gpuLarge)
        // The old "force CoreList on" switch does not turn into the new opt-out.
        XCTAssertFalse(settings.forceListViewImplChatBackend)
    }

    func testRoundTrip() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.forceListViewImplChatBackend = true
        settings.enableVoipTcp = true
        let decoded = try EngineDecoder.decode(ExperimentalUISettings.self, from: try EngineEncoder.encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}
