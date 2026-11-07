import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ChatRowPrep
@testable import DebugSettingsUI

/// The "Chat scroll" Debug Settings section: two switches for the chat-scroll experiments. They start off, sit in their own
/// section and are only offered in the main app.
final class ChatScrollSwitchesTests: XCTestCase {
    private func entries(isMainApp: Bool, settings: ExperimentalUISettings) -> [DebugControllerEntry] {
        let environment = DebugControllerEntriesEnvironment(isMainApp: isMainApp, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        return debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: settings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
    }

    private func isOn(_ entry: DebugControllerEntry) -> Bool? {
        switch entry {
        case let .chatScrollPrepareLayoutAhead(value), let .chatScrollReuseRowViews(value):
            return value
        default:
            return nil
        }
    }

    func testTheSwitchesAreOnByDefault() {
        XCTAssertEqual(ExperimentalUISettings.defaultSettings.chatScrollExperiments, 3)
        let all = self.entries(isMainApp: true, settings: .defaultSettings)
        XCTAssertEqual(all.compactMap { self.isOn($0) }, [true, true])
    }

    func testEachSwitchShowsItsBit() {
        var settings = ExperimentalUISettings.defaultSettings
        settings.chatScrollExperiments = ExperimentalUISettings.chatScrollReuseRowViews
        XCTAssertEqual(self.entries(isMainApp: true, settings: settings).compactMap { self.isOn($0) }, [false, true])
        settings.chatScrollExperiments = ExperimentalUISettings.chatScrollPrepareLayoutAhead
        XCTAssertEqual(self.entries(isMainApp: true, settings: settings).compactMap { self.isOn($0) }, [true, false])
    }

    func testTheSettingsBitsAreTheExperimentBits() {
        XCTAssertEqual(ExperimentalUISettings.chatScrollPrepareLayoutAhead, ChatScrollExperiment.prepareLayoutAhead.rawValue)
        XCTAssertEqual(ExperimentalUISettings.chatScrollReuseRowViews, ChatScrollExperiment.reuseRowViews.rawValue)
        XCTAssertEqual(ChatScrollExperiment.allCases.count, 2)
    }

    func testTheSectionIsBehindItsHeaderAndSeparate() {
        let expected: [DebugControllerEntry] = [.chatScrollHeader(defaultPresentationTheme), .chatScrollPrepareLayoutAhead(false), .chatScrollReuseRowViews(false)]
        let all = self.entries(isMainApp: true, settings: .defaultSettings)
        guard let start = all.firstIndex(where: { $0.stableId == expected[0].stableId && $0.section == expected[0].section }) else {
            XCTFail("no Chat scroll header")
            return
        }
        XCTAssertEqual(Array(all[start ..< start + expected.count]).map { $0.stableId }, expected.map { $0.stableId })
        XCTAssertEqual(all.filter { $0.section == expected[0].section }.count, expected.count)
        XCTAssertNotEqual(expected[0].section, DebugControllerEntry.glassGroupsHeader(defaultPresentationTheme).section)
        XCTAssertNotEqual(expected[0].section, DebugControllerEntry.callsHeader(defaultPresentationTheme).section)
    }

    func testOnlyTheMainAppOffersThem() {
        let all = self.entries(isMainApp: false, settings: .defaultSettings)
        XCTAssertTrue(all.compactMap { self.isOn($0) }.isEmpty)
    }
}
