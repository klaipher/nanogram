import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// "Emoji panel: defer first-responder handoff / heavy layers": off by default, its own section, main app only, and settings
/// saved by older builds (no key) decode as off.
final class EmojiPanelSwitchTests: XCTestCase {
    private func entries(isMainApp: Bool, settings: ExperimentalUISettings) -> [DebugControllerEntry] {
        let environment = DebugControllerEntriesEnvironment(isMainApp: isMainApp, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        return debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: settings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
    }

    private func switchValues(_ entries: [DebugControllerEntry]) -> [Bool] {
        return entries.compactMap { entry -> Bool? in
            if case let .emojiPanelDefersHeavyWork(value) = entry {
                return value
            }
            return nil
        }
    }

    func testTheSwitchIsOnByDefault() {
        XCTAssertTrue(ExperimentalUISettings.defaultSettings.emojiPanelDefersHeavyWork)
        XCTAssertEqual(self.switchValues(self.entries(isMainApp: true, settings: .defaultSettings)), [true])
    }

    func testTheSwitchShowsItsValue() {
        var settings = ExperimentalUISettings.defaultSettings
        settings.emojiPanelDefersHeavyWork = false
        XCTAssertEqual(self.switchValues(self.entries(isMainApp: true, settings: settings)), [false])
    }

    func testTheSwitchHasItsOwnSectionBehindAHeader() {
        let all = self.entries(isMainApp: true, settings: .defaultSettings)
        let header = DebugControllerEntry.emojiPanelHeader(defaultPresentationTheme)
        guard let start = all.firstIndex(where: { $0.stableId == header.stableId && $0.section == header.section }) else {
            XCTFail("no Emoji panel header")
            return
        }
        XCTAssertEqual(all[start + 1].stableId, DebugControllerEntry.emojiPanelDefersHeavyWork(false).stableId)
        XCTAssertEqual(all.filter { $0.section == header.section }.count, 2)
        XCTAssertNotEqual(header.section, DebugControllerEntry.glassGroupsHeader(defaultPresentationTheme).section)
    }

    func testOnlyTheMainAppOffersIt() {
        XCTAssertTrue(self.switchValues(self.entries(isMainApp: false, settings: .defaultSettings)).isEmpty)
    }
}
