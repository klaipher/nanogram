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

    func testAChoiceMadeAfterTheUpgradeIsKept() throws {
        var settings = try self.decode(#"{"compressedEmojiCache": 0, "stickerRendererMode": "cpu"}"#)
        settings.stickerRendererMode = .cpu
        settings.compressedEmojiCache = false
        let saved = try self.roundTrip(settings)
        XCTAssertEqual(saved.stickerRendererMode, .cpu)
        XCTAssertFalse(saved.compressedEmojiCache)
        XCTAssertEqual(try self.roundTrip(saved).stickerRendererMode, .cpu)
    }

    func testGPUForAllIsNotDowngraded() throws {
        let settings = try self.decode(#"{"compressedEmojiCache": 1, "stickerRendererMode": "gpuAll"}"#)
        XCTAssertEqual(settings.stickerRendererMode, .gpuAll)
        XCTAssertTrue(settings.compressedEmojiCache)
    }
}
