import XCTest
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The "Glass groups" Debug Settings section: measurement switches that replace one chat glass group with a solid
/// fill. They start off, sit in their own section (not the calls section) and are only offered in the main app.
final class GlassGroupsSwitchesTests: XCTestCase {
    private func entries(isMainApp: Bool, settings: ExperimentalUISettings) -> [DebugControllerEntry] {
        let environment = DebugControllerEntriesEnvironment(isMainApp: isMainApp, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        return debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: settings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
    }

    private func isOn(_ entry: DebugControllerEntry) -> Bool? {
        switch entry {
        case let .glassGroupNavigationBar(value), let .glassGroupInputPanel(value), let .glassGroupFloatingButtons(value):
            return value
        default:
            return nil
        }
    }

    func testTheSwitchesAreOffByDefault() {
        let all = self.entries(isMainApp: true, settings: .defaultSettings)
        let switches = all.compactMap { self.isOn($0) }
        XCTAssertEqual(switches, [false, false, false])
    }

    func testEachSwitchShowsItsBit() {
        var settings = ExperimentalUISettings.defaultSettings
        settings.glassDebugDisabledGroups = ExperimentalUISettings.glassDebugInputPanel
        XCTAssertEqual(self.entries(isMainApp: true, settings: settings).compactMap { self.isOn($0) }, [false, true, false])
        settings.glassDebugDisabledGroups = ExperimentalUISettings.glassDebugNavigationBar | ExperimentalUISettings.glassDebugFloatingButtons
        XCTAssertEqual(self.entries(isMainApp: true, settings: settings).compactMap { self.isOn($0) }, [true, false, true])
    }

    func testTheSectionIsBehindItsHeaderAndSeparateFromTheCallsSection() {
        let expected: [DebugControllerEntry] = [.glassGroupsHeader(defaultPresentationTheme), .glassGroupNavigationBar(false), .glassGroupInputPanel(false), .glassGroupFloatingButtons(false)]
        let all = self.entries(isMainApp: true, settings: .defaultSettings)
        guard let start = all.firstIndex(where: { $0.stableId == expected[0].stableId && $0.section == expected[0].section }) else {
            XCTFail("no Glass groups header")
            return
        }
        XCTAssertEqual(Array(all[start ..< start + expected.count]).map { $0.stableId }, expected.map { $0.stableId })
        XCTAssertEqual(all.filter { $0.section == expected[0].section }.count, expected.count)
        XCTAssertNotEqual(expected[0].section, DebugControllerEntry.callsHeader(defaultPresentationTheme).section)
    }

    func testOnlyTheMainAppOffersThem() {
        let all = self.entries(isMainApp: false, settings: .defaultSettings)
        XCTAssertTrue(all.compactMap { self.isOn($0) }.isEmpty)
    }
}
