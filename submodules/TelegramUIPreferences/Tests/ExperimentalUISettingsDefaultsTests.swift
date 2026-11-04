import XCTest
@testable import TelegramUIPreferences

/// The CPU sticker renderer and the plain emoji cache are the defaults again (revision 2; revision 1 had forced
/// the Metal and YUVA paths on every blob). A blob written at revision 1 is reverted once, and a choice made
/// after that is kept.
final class ExperimentalUISettingsDefaultsTests: XCTestCase {
    private func decode(_ json: String) throws -> ExperimentalUISettings {
        return try JSONDecoder().decode(ExperimentalUISettings.self, from: Data(json.utf8))
    }

    private func roundTrip(_ settings: ExperimentalUISettings) throws -> ExperimentalUISettings {
        return try JSONDecoder().decode(ExperimentalUISettings.self, from: JSONEncoder().encode(settings))
    }

    func testNewInstallsUseTheCPURenderers() {
        let settings = ExperimentalUISettings.defaultSettings
        XCTAssertEqual(settings.stickerRendererMode, .cpu)
        XCTAssertFalse(settings.compressedEmojiCache)
    }

    func testAnEmptyBlobUsesTheCPURenderers() throws {
        let settings = try self.decode("{}")
        XCTAssertEqual(settings.stickerRendererMode, .cpu)
        XCTAssertFalse(settings.compressedEmojiCache)
    }

    func testRevisionOneDefaultsAreRevertedOnce() throws {
        // What revision 1 forced: large stickers on Metal, custom emoji on the YUVA path.
        let settings = try self.decode(#"{"nanogramDefaultsRevision": 1, "compressedEmojiCache": 1, "stickerRendererMode": "gpuLarge", "fakeGlass": 1}"#)
        XCTAssertEqual(settings.stickerRendererMode, .cpu)
        XCTAssertFalse(settings.compressedEmojiCache)
        XCTAssertTrue(settings.fakeGlass, "other flags are kept")
    }

    func testBlobsOlderThanRevisionOneKeepTheirValues() throws {
        let settings = try self.decode(#"{"compressedEmojiCache": 0, "stickerRendererMode": "cpu", "fakeGlass": 1}"#)
        XCTAssertEqual(settings.stickerRendererMode, .cpu)
        XCTAssertFalse(settings.compressedEmojiCache)
        XCTAssertTrue(settings.fakeGlass)
    }

    func testAChoiceMadeAfterTheRevertIsKept() throws {
        var settings = try self.decode(#"{"nanogramDefaultsRevision": 1, "compressedEmojiCache": 1, "stickerRendererMode": "gpuLarge"}"#)
        settings.stickerRendererMode = .gpuLarge
        settings.compressedEmojiCache = true
        let saved = try self.roundTrip(settings)
        XCTAssertEqual(saved.stickerRendererMode, .gpuLarge)
        XCTAssertTrue(saved.compressedEmojiCache)
        XCTAssertEqual(try self.roundTrip(saved).stickerRendererMode, .gpuLarge)
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
        let settings = try self.decode(#"{"nanogramDefaultsRevision": 2, "compressedEmojiCache": 1, "stickerRendererMode": "gpuAll"}"#)
        XCTAssertEqual(settings.stickerRendererMode, .gpuAll)
        XCTAssertTrue(settings.compressedEmojiCache)
    }
}
