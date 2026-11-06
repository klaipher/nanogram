import XCTest
import HardenedMedia
import ChatMessageWidgetBubbleContentNode

/// Whether widget messages render as widgets: the server's kill switch, this device's switch (Debug Settings, on by
/// default) and the hardened media policy (Lockdown Mode) must all allow it.
final class MessageWidgetRenderingGateTests: XCTestCase {
    func testWidgetsRenderOnlyWhenNothingSwitchesThemOff() {
        XCTAssertTrue(chatMessageWidgetRenderingEnabled(serverKillSwitchEngaged: false, localSwitchOn: true, policy: .inactive))
        XCTAssertFalse(chatMessageWidgetRenderingEnabled(serverKillSwitchEngaged: true, localSwitchOn: true, policy: .inactive))
        XCTAssertFalse(chatMessageWidgetRenderingEnabled(serverKillSwitchEngaged: false, localSwitchOn: false, policy: .inactive))
    }

    func testLockdownModeShowsThePillInsteadOfRunningWidgets() {
        XCTAssertFalse(chatMessageWidgetRenderingEnabled(serverKillSwitchEngaged: false, localSwitchOn: true, policy: .lockdown))
    }
}
