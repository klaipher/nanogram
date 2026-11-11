import XCTest
@testable import MessageWidget

final class LocalSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "LocalSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            XCTFail("no defaults suite")
            return .standard
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testWidgetsAreOffOnAFreshInstall() {
        XCTAssertFalse(MessageWidgetLocalSettings.widgetsEnabled(defaults: self.freshDefaults()))
    }

    func testAnOldOnChoiceDoesNotTurnWidgetsOn() {
        let defaults = self.freshDefaults()
        defaults.set(true, forKey: "nanogram.messageWidgets.enabled")
        XCTAssertFalse(MessageWidgetLocalSettings.widgetsEnabled(defaults: defaults))
    }

    func testTheDebugSwitchTurnsWidgetsOnAndOff() {
        let defaults = self.freshDefaults()
        MessageWidgetLocalSettings.setWidgetsEnabled(true, defaults: defaults)
        XCTAssertTrue(MessageWidgetLocalSettings.widgetsEnabled(defaults: defaults))
        MessageWidgetLocalSettings.setWidgetsEnabled(false, defaults: defaults)
        XCTAssertFalse(MessageWidgetLocalSettings.widgetsEnabled(defaults: defaults))
    }
}
