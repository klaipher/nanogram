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

    func testEmojiPanelDeferralIsOnByDefaultAndTheChoiceIsKept() throws {
        XCTAssertTrue(try self.decode("{}").emojiPanelDefersHeavyWork)
        XCTAssertTrue(ExperimentalUISettings.defaultSettings.emojiPanelDefersHeavyWork)
        XCTAssertTrue(try self.decode(#"{"emojiPanelDefersHeavyWork": 0}"#).emojiPanelDefersHeavyWork, "the off-by-default key is not read")
        var settings = ExperimentalUISettings.defaultSettings
        settings.emojiPanelDefersHeavyWork = false
        XCTAssertFalse(try self.roundTrip(settings).emojiPanelDefersHeavyWork)
    }

    func testChatOpenDeferSetupIsOnByDefaultAndTheChoiceIsKept() throws {
        XCTAssertTrue(ExperimentalUISettings.defaultSettings.chatOpenDeferSetup)
        XCTAssertTrue(try self.decode("{}").chatOpenDeferSetup)
        XCTAssertTrue(try self.decode(#"{"glassDebugDisabledGroups": 2, "chatOpenDeferSetup": 0}"#).chatOpenDeferSetup, "blobs of older builds follow the new default")
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatOpenDeferSetup = false
        XCTAssertFalse(try self.roundTrip(settings).chatOpenDeferSetup)
        XCTAssertTrue(try self.roundTrip(try self.roundTrip(settings).withChatOpenDeferSetup(true)).chatOpenDeferSetup)
    }

    func testChatOpenWallpaperPrewarmIsOnByDefaultAndTheChoiceIsKept() throws {
        XCTAssertTrue(ExperimentalUISettings.defaultSettings.chatOpenPrewarmWallpaperPattern)
        XCTAssertTrue(try self.decode("{}").chatOpenPrewarmWallpaperPattern)
        XCTAssertTrue(try self.decode(#"{"chatOpenPrewarmWallpaperPattern": 0}"#).chatOpenPrewarmWallpaperPattern, "only the DefaultOn key counts")
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatOpenPrewarmWallpaperPattern = false
        XCTAssertFalse(try self.roundTrip(settings).chatOpenPrewarmWallpaperPattern)
        XCTAssertTrue(try self.roundTrip(settings).chatOpenDeferSetup, "the two chat open switches are independent")
    }

    func testChatScrollExperimentsAreOnByDefaultAndTheChoiceIsKept() throws {
        XCTAssertEqual(try self.decode("{}").chatScrollExperiments, 3)
        XCTAssertEqual(ExperimentalUISettings.defaultSettings.chatScrollExperiments, 3)
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatScrollExperiments = ExperimentalUISettings.chatScrollReuseRowViews
        XCTAssertEqual(try self.roundTrip(settings).chatScrollExperiments, 2)
        settings.chatScrollExperiments = 0
        XCTAssertEqual(try self.roundTrip(settings).chatScrollExperiments, 0)
        // A blob saved while the switches were off by default keeps the other flags and gets both switches on.
        let older = try self.decode(#"{"fakeGlass": 1, "glassDebugDisabledGroups": 2, "chatScrollExperiments": 0}"#)
        XCTAssertEqual(older.chatScrollExperiments, 3)
        XCTAssertEqual(older.glassDebugDisabledGroups, 2)
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

    func testTheIPadDisplayLinkCapIsOnByDefaultAndTheChoiceIsKept() throws {
        XCTAssertTrue(ExperimentalUISettings.defaultSettings.tabletDisplayLinkFrameRateCap)
        XCTAssertTrue(try self.decode("{}").tabletDisplayLinkFrameRateCap)
        XCTAssertTrue(try self.decode(#"{"tabletDisplayLinkFrameRateCap": 0}"#).tabletDisplayLinkFrameRateCap, "the off-by-default key is not read")
        var settings = ExperimentalUISettings.defaultSettings
        settings.tabletDisplayLinkFrameRateCap = false
        XCTAssertFalse(try self.roundTrip(settings).tabletDisplayLinkFrameRateCap)
    }

    func testListScrollABSwitchesAreOffByDefaultAndTheChoiceIsKept() throws {
        for settings in [ExperimentalUISettings.defaultSettings, try self.decode("{}"), try self.decode(#"{"glassDebugDisabledGroups": 2}"#)] {
            XCTAssertFalse(settings.displayLinkUpstreamRate)
            XCTAssertFalse(settings.listAccessibilityImmediate)
            XCTAssertFalse(settings.listScrollPacingLog)
        }
        var settings = ExperimentalUISettings.defaultSettings
        settings.displayLinkUpstreamRate = true
        settings.listAccessibilityImmediate = true
        settings.listScrollPacingLog = true
        let saved = try self.roundTrip(settings)
        XCTAssertTrue(saved.displayLinkUpstreamRate)
        XCTAssertTrue(saved.listAccessibilityImmediate)
        XCTAssertTrue(saved.listScrollPacingLog)
    }

    func testChatListLazyRareSubnodesIsOnByDefaultAndTheChoiceIsKept() throws {
        for settings in [ExperimentalUISettings.defaultSettings, try self.decode("{}"), try self.decode(#"{"glassDebugDisabledGroups": 2}"#)] {
            XCTAssertTrue(settings.chatListLazyRareSubnodes)
        }
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatListLazyRareSubnodes = false
        XCTAssertFalse(try self.roundTrip(settings).chatListLazyRareSubnodes)
    }

    func testChatListAsyncMediaWhileScrollingIsOnByDefaultAndTheChoiceIsKept() throws {
        for settings in [ExperimentalUISettings.defaultSettings, try self.decode("{}"), try self.decode(#"{"glassDebugDisabledGroups": 2}"#)] {
            XCTAssertTrue(settings.chatListAsyncMediaWhileScrolling)
        }
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatListAsyncMediaWhileScrolling = false
        XCTAssertFalse(try self.roundTrip(settings).chatListAsyncMediaWhileScrolling)
    }

    func testBackSwipePreparePreviousScreenIsOffByDefaultAndTheChoiceIsKept() throws {
        for settings in [ExperimentalUISettings.defaultSettings, try self.decode("{}"), try self.decode(#"{"glassDebugDisabledGroups": 2}"#)] {
            XCTAssertFalse(settings.backSwipePreparePreviousScreen)
        }
        var settings = ExperimentalUISettings.defaultSettings
        settings.backSwipePreparePreviousScreen = true
        XCTAssertTrue(try self.roundTrip(settings).backSwipePreparePreviousScreen)
    }

    func testChatListRowReuseIsOffByDefaultAndTheChoiceIsKept() throws {
        for settings in [ExperimentalUISettings.defaultSettings, try self.decode("{}"), try self.decode(#"{"glassDebugDisabledGroups": 2}"#)] {
            XCTAssertFalse(settings.chatListRowReuse)
        }
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatListRowReuse = true
        XCTAssertTrue(try self.roundTrip(settings).chatListRowReuse)
    }

    /// Debug Settings "Perf A/B": one tap sets every switch of this round to our variant or to Telegram's behaviour.
    func testPerformanceSwitchesCanAllBeSetToTelegramsBehaviour() {
        let telegram = ExperimentalUISettings.defaultSettings.withPerformanceSwitches(optimized: false)
        XCTAssertFalse(telegram.emojiPanelDefersHeavyWork)
        XCTAssertFalse(telegram.chatOpenDeferSetup)
        XCTAssertFalse(telegram.chatOpenPrewarmWallpaperPattern)
        XCTAssertTrue(telegram.displayLinkUpstreamRate, "Telegram's rate is the switch's on state")
        XCTAssertTrue(telegram.listAccessibilityImmediate, "Telegram's accessibility timing is the switch's on state")
        XCTAssertFalse(telegram.chatListLazyRareSubnodes)
        XCTAssertFalse(telegram.chatListRowReuse)
        XCTAssertFalse(telegram.chatListAsyncMediaWhileScrolling)
        XCTAssertFalse(telegram.backSwipePreparePreviousScreen)
        XCTAssertEqual(telegram.chatScrollExperiments, 0)
        XCTAssertEqual(telegram.stickerRendererMode, ExperimentalUISettings.defaultSettings.stickerRendererMode, "renderers are not part of the A/B")
    }

    func testPerformanceSwitchesCanAllBeSetToOurs() {
        let ours = ExperimentalUISettings.defaultSettings.withPerformanceSwitches(optimized: false).withPerformanceSwitches(optimized: true)
        XCTAssertTrue(ours.emojiPanelDefersHeavyWork)
        XCTAssertTrue(ours.chatOpenDeferSetup)
        XCTAssertTrue(ours.chatOpenPrewarmWallpaperPattern)
        XCTAssertFalse(ours.displayLinkUpstreamRate)
        XCTAssertFalse(ours.listAccessibilityImmediate)
        XCTAssertTrue(ours.chatListLazyRareSubnodes)
        XCTAssertTrue(ours.chatListRowReuse)
        XCTAssertTrue(ours.chatListAsyncMediaWhileScrolling)
        XCTAssertTrue(ours.backSwipePreparePreviousScreen)
        XCTAssertEqual(ours.chatScrollExperiments, 3)
    }

    /// Every log line that measures something names every switch it ran with.
    func testPerformanceSummaryNamesEverySwitch() {
        let summary = ExperimentalUISettings.defaultSettings.withPerformanceSwitches(optimized: false).performanceSwitchesSummary
        XCTAssertEqual(summary, "set=telegram emojiDefer=off openDefer=off wallPrewarm=off upstreamRate=on a11yNow=on lazyRows=off rowReuse=off asyncMedia=off backPrep=off chatRows=0 ipadCap=on")
        XCTAssertTrue(ExperimentalUISettings.defaultSettings.withPerformanceSwitches(optimized: true).performanceSwitchesSummary.hasPrefix("set=ours "))
        var mixed = ExperimentalUISettings.defaultSettings.withPerformanceSwitches(optimized: true)
        mixed.chatListRowReuse = false
        XCTAssertTrue(mixed.performanceSwitchesSummary.hasPrefix("set=mixed "))
    }
}

private extension ExperimentalUISettings {
    func withChatOpenDeferSetup(_ value: Bool) -> ExperimentalUISettings {
        var settings = self
        settings.chatOpenDeferSetup = value
        return settings
    }
}
