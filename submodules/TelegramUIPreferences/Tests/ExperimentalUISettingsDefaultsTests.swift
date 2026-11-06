import XCTest
@testable import TelegramUIPreferences

/// Large stickers on the Metal renderer and custom emoji on the YUVA path are on by default (both checked on
/// the owner's iPhone). The settings blob is saved whole, so a phone that ever saved debug settings already
/// holds the old defaults; it is upgraded once, and a choice made after that is kept.
final class ExperimentalUISettingsDefaultsTests: XCTestCase {
    private func decode(_ json: String) throws -> ExperimentalUISettings {
        return try JSONDecoder().decode(ExperimentalUISettings.self, from: Data(json.utf8))
    }

    private func roundTrip(_ settings: ExperimentalUISettings) throws -> ExperimentalUISettings {
        return try JSONDecoder().decode(ExperimentalUISettings.self, from: JSONEncoder().encode(settings))
    }

    func testNewInstallsUseTheGPURenderers() {
        let settings = ExperimentalUISettings.defaultSettings
        XCTAssertEqual(settings.stickerRendererMode, .gpuLarge)
        XCTAssertTrue(settings.compressedEmojiCache)
    }

    func testAnEmptyBlobUsesTheGPURenderers() throws {
        let settings = try self.decode("{}")
        XCTAssertEqual(settings.stickerRendererMode, .gpuLarge)
        XCTAssertTrue(settings.compressedEmojiCache)
    }

    func testSettingsSavedWithTheOldDefaultsAreUpgradedOnce() throws {
        // What builds before this change wrote: both renderers on the CPU, no revision key.
        let settings = try self.decode(#"{"compressedEmojiCache": 0, "stickerRendererMode": "cpu", "fakeGlass": 1}"#)
        XCTAssertEqual(settings.stickerRendererMode, .gpuLarge)
        XCTAssertTrue(settings.compressedEmojiCache)
        XCTAssertTrue(settings.fakeGlass, "other flags are kept")
    }

    func testGlassGroupsAreAllOnByDefaultAndTheChoiceIsKept() throws {
        XCTAssertEqual(try self.decode("{}").glassDebugDisabledGroups, 0)
        XCTAssertEqual(ExperimentalUISettings.defaultSettings.glassDebugDisabledGroups, 0)
        var settings = ExperimentalUISettings.defaultSettings
        settings.glassDebugDisabledGroups = ExperimentalUISettings.glassDebugInputPanel | ExperimentalUISettings.glassDebugFloatingButtons
        let saved = try self.roundTrip(settings)
        XCTAssertEqual(saved.glassDebugDisabledGroups, 6)
    }

    func testEmojiPanelDeferralIsOffByDefaultAndTheChoiceIsKept() throws {
        XCTAssertFalse(try self.decode("{}").emojiPanelDefersHeavyWork)
        XCTAssertFalse(ExperimentalUISettings.defaultSettings.emojiPanelDefersHeavyWork)
        var settings = ExperimentalUISettings.defaultSettings
        settings.emojiPanelDefersHeavyWork = true
        XCTAssertTrue(try self.roundTrip(settings).emojiPanelDefersHeavyWork)
    }

    func testChatOpenDeferSetupIsOffByDefaultAndTheChoiceIsKept() throws {
        XCTAssertFalse(ExperimentalUISettings.defaultSettings.chatOpenDeferSetup)
        XCTAssertFalse(try self.decode("{}").chatOpenDeferSetup)
        XCTAssertFalse(try self.decode(#"{"glassDebugDisabledGroups": 2}"#).chatOpenDeferSetup, "blobs of older builds have no key")
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatOpenDeferSetup = true
        XCTAssertTrue(try self.roundTrip(settings).chatOpenDeferSetup)
        XCTAssertFalse(try self.roundTrip(try self.roundTrip(settings).withChatOpenDeferSetup(false)).chatOpenDeferSetup)
    }

    func testAChoiceMadeAfterTheUpgradeIsKept() throws {
        var settings = try self.decode(#"{"compressedEmojiCache": 0, "stickerRendererMode": "cpu"}"#)
        settings.stickerRendererMode = .cpu
        settings.compressedEmojiCache = false
        let saved = try self.roundTrip(settings)
        XCTAssertEqual(saved.stickerRendererMode, .cpu)
        XCTAssertFalse(saved.compressedEmojiCache)
        XCTAssertEqual(try self.roundTrip(saved).stickerRendererMode, .cpu)
    }

    /// Debug Settings ▸ "Circle Colour Decode": a new key, so existing installs (any revision) and unknown values
    /// get the BT.709 default, and a choice is kept.
    func testCircleColourDecodeDefaultsToBT709() throws {
        XCTAssertEqual(ExperimentalUISettings.defaultSettings.videoMessageCameraMatrix, .bt709)
        XCTAssertEqual(try self.decode("{}").videoMessageCameraMatrix, .bt709)
        XCTAssertEqual(try self.decode(#"{"nanogramDefaultsRevision": 1, "videoMessageCameraMode": "vga"}"#).videoMessageCameraMatrix, .bt709)
        XCTAssertEqual(try self.decode(#"{"videoMessageCameraMatrix": "unknown"}"#).videoMessageCameraMatrix, .bt709)
        for matrix in ExperimentalUISettings.RoundVideoCameraMatrix.allCases {
            var settings = ExperimentalUISettings.defaultSettings
            settings.videoMessageCameraMatrix = matrix
            XCTAssertEqual(try self.roundTrip(settings).videoMessageCameraMatrix, matrix)
        }
    }

    func testGPUForAllIsNotDowngraded() throws {
        let settings = try self.decode(#"{"compressedEmojiCache": 1, "stickerRendererMode": "gpuAll"}"#)
        XCTAssertEqual(settings.stickerRendererMode, .gpuAll)
        XCTAssertTrue(settings.compressedEmojiCache)
    }
}

private extension ExperimentalUISettings {
    func withChatOpenDeferSetup(_ value: Bool) -> ExperimentalUISettings {
        var settings = self
        settings.chatOpenDeferSetup = value
        return settings
    }
}
