import XCTest
import UserNotifications
@testable import NotificationServiceExtensionLib

final class IncomingCallPushPresentationTests: XCTestCase {
    // CXProvider.reportNewIncomingVoIPPushPayload needs the notification filtering entitlement:
    // without it the call must become a notification, whatever the CallKit setting says.
    func testCallKitOnlyWithSystemIntegrationAndFiltering() {
        XCTAssertTrue(IncomingCallPushPresentation.reportsToCallKit(systemIntegrationEnabled: true, canFilterNotifications: true))
        XCTAssertFalse(IncomingCallPushPresentation.reportsToCallKit(systemIntegrationEnabled: true, canFilterNotifications: false))
        XCTAssertFalse(IncomingCallPushPresentation.reportsToCallKit(systemIntegrationEnabled: false, canFilterNotifications: true))
        XCTAssertFalse(IncomingCallPushPresentation.reportsToCallKit(systemIntegrationEnabled: false, canFilterNotifications: false))
    }

    func testAlertNamesTheCaller() {
        let alert = IncomingCallPushPresentation.alert(callerName: "Alice", incomingCallMessage: "is calling you")
        XCTAssertEqual(alert.title, "Alice")
        XCTAssertEqual(alert.body, "is calling you")
    }

    func testAlertWithoutCallerStillShows() {
        for name in [nil, ""] as [String?] {
            let alert = IncomingCallPushPresentation.alert(callerName: name, incomingCallMessage: "is calling you")
            XCTAssertNil(alert.title)
            XCTAssertEqual(alert.body, "Incoming Call")
        }
    }

    // Tapping opens the caller's chat on the account the call is for, where the ringing call shows.
    func testUserInfoOpensTheCallersChatOnTheRightAccount() {
        let userInfo = IncomingCallPushPresentation.userInfo(accountId: 42, peerId: 1234, fromUserId: 1234)
        XCTAssertEqual(userInfo["accountId"] as? String, "42")
        XCTAssertEqual(userInfo["peerId"] as? String, "1234")
        XCTAssertEqual(userInfo["from_id"] as? String, "1234")
        XCTAssertTrue(IncomingCallPushPresentation.isIncomingCall(userInfo: userInfo))
        XCTAssertFalse(ServicePushPresentation.isQuietPlaceholder(userInfo: userInfo))
    }

    func testMarker() {
        XCTAssertTrue(IncomingCallPushPresentation.isIncomingCall(userInfo: IncomingCallPushPresentation.markerUserInfo))
        XCTAssertFalse(IncomingCallPushPresentation.isIncomingCall(userInfo: ["p": "encrypted"]))
    }

    func testRingsWithTheRingtone() throws {
        guard #available(iOS 15.2, *) else {
            throw XCTSkip("no ringtone sound before iOS 15.2")
        }
        XCTAssertEqual(IncomingCallPushPresentation.sound, UNNotificationSound.defaultRingtone)
    }
}
