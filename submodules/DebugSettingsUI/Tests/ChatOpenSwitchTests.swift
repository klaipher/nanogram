import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The "Chat open: defer non-visible setup" switch: off by default, in its own section, main app only.
final class ChatOpenSwitchTests: XCTestCase {
    private func entries(isMainApp: Bool, settings: ExperimentalUISettings) -> [DebugControllerEntry] {
        let environment = DebugControllerEntriesEnvironment(isMainApp: isMainApp, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        return debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: settings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
    }

    private func value(_ entry: DebugControllerEntry) -> Bool? {
        if case let .chatOpenDeferSetup(value) = entry {
            return value
        }
        return nil
    }

    func testTheSwitchIsOnByDefaultAndShowsTheSetting() {
        XCTAssertEqual(self.entries(isMainApp: true, settings: .defaultSettings).compactMap { self.value($0) }, [true])
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatOpenDeferSetup = false
        XCTAssertEqual(self.entries(isMainApp: true, settings: settings).compactMap { self.value($0) }, [false])
    }

    func testTheSwitchHasItsOwnSectionBehindItsHeader() {
        let all = self.entries(isMainApp: true, settings: .defaultSettings)
        let header = DebugControllerEntry.chatOpenHeader(defaultPresentationTheme)
        guard let start = all.firstIndex(where: { $0.stableId == header.stableId }) else {
            XCTFail("no Chat open header")
            return
        }
        XCTAssertEqual(all[start + 1].stableId, DebugControllerEntry.chatOpenDeferSetup(false).stableId)
        XCTAssertEqual(all.filter { $0.section == header.section }.count, 2)
        XCTAssertNotEqual(header.section, DebugControllerEntry.glassGroupsHeader(defaultPresentationTheme).section)
        XCTAssertNotEqual(header.section, DebugControllerEntry.callsHeader(defaultPresentationTheme).section)
    }

    func testOnlyTheMainAppOffersIt() {
        XCTAssertTrue(self.entries(isMainApp: false, settings: .defaultSettings).compactMap { self.value($0) }.isEmpty)
    }
}
