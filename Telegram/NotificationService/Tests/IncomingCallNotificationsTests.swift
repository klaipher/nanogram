import XCTest
import NotificationsPresentationData
@testable import NotificationServiceExtensionLib

final class IncomingCallNotificationsTests: XCTestCase {
    private func callNotification(_ identifier: String, peerId: Int64, date: Date = Date(timeIntervalSince1970: 1000)) -> (identifier: String, userInfo: [AnyHashable: Any], date: Date) {
        return (identifier, IncomingCallPushPresentation.userInfo(accountId: 7, peerId: peerId, fromUserId: peerId), date)
    }

    // The extension writes the marker and the app reads it: both must use the same key.
    func testExtensionAndAppShareTheMarker() {
        XCTAssertEqual(IncomingCallPushPresentation.userInfoKey, IncomingCallNotifications.userInfoKey)
        XCTAssertTrue(IncomingCallNotifications.isIncomingCall(userInfo: IncomingCallPushPresentation.markerUserInfo))
    }

    // Once the app rings the call itself (CallKit) or the call stops ringing, the extension's
    // ringing notification for that caller goes, and nothing else does.
    func testRemovesOnlyThisCallersCallNotifications() {
        let delivered = [
            callNotification("a", peerId: 100),
            callNotification("b", peerId: 200),
            (identifier: "message", userInfo: ["peerId": "100", "accountId": "7"] as [AnyHashable: Any], date: Date(timeIntervalSince1970: 1000)),
            (identifier: "service", userInfo: [ServicePushNotifications.placeholderUserInfoKey: true] as [AnyHashable: Any], date: Date(timeIntervalSince1970: 1000))
        ]
        let identifiers = IncomingCallNotifications.identifiers(delivered: delivered.map { ($0.identifier, $0.userInfo) }, peerId: 100)
        XCTAssertEqual(identifiers, ["a"])
    }

    // A call rings for at most the server's ring timeout (90 s by default): a call notification
    // older than that is a leftover, whatever happened to the call.
    func testCallNotificationsOutliveNoRing() {
        let now = Date(timeIntervalSince1970: 1000)
        let delivered = [
            callNotification("fresh", peerId: 100, date: now.addingTimeInterval(-10)),
            callNotification("old", peerId: 200, date: now.addingTimeInterval(-(IncomingCallNotifications.ringTimeout + 1))),
            (identifier: "message", userInfo: ["peerId": "100"] as [AnyHashable: Any], date: now.addingTimeInterval(-1000))
        ]
        XCTAssertEqual(IncomingCallNotifications.staleIdentifiers(delivered: delivered, now: now), ["old"])
    }

    // CallKit rings the call the app reported: the notification's ringtone must not ring with it.
    // Without CallKit it stays until the call stops ringing (answered, declined, missed, ended).
    func testWhenTheAppTakesOverTheRinging() {
        XCTAssertTrue(IncomingCallNotifications.appRingsOrCallEnded(isIntegratedWithCallKit: true, isRinging: true))
        XCTAssertTrue(IncomingCallNotifications.appRingsOrCallEnded(isIntegratedWithCallKit: false, isRinging: false))
        XCTAssertFalse(IncomingCallNotifications.appRingsOrCallEnded(isIntegratedWithCallKit: false, isRinging: true))
    }

    // MARK: - Calling back from a donated call

    // The person of a call notification's INStartCallIntent names the account the call came to
    // and the caller; "call back" (AppDelegate) calls from that account, not the active one.
    func testCallBackIdentifierRoundTrips() {
        let identifier = IncomingCallNotifications.callBackIdentifier(accountId: -8_123_456_789_012, peerId: 1234)
        XCTAssertEqual(IncomingCallNotifications.callBack(identifier: identifier), IncomingCallNotifications.CallBack(accountId: -8_123_456_789_012, peerId: 1234))
        let other = IncomingCallNotifications.callBackIdentifier(accountId: 42, peerId: Int64.max)
        XCTAssertEqual(IncomingCallNotifications.callBack(identifier: other), IncomingCallNotifications.CallBack(accountId: 42, peerId: Int64.max))
    }

    // Handles that are not the extension's (Siri, the system's call history, the older "tg<peer>"
    // custom identifiers and bare peer ids) are left to the existing call-back paths.
    func testOtherHandlesAreNotCallBacks() {
        for identifier in ["1234", "tg1234", "+15551234567", "", "nanogram-call:", "nanogram-call:42", "nanogram-call:42:x", "nanogram-call:42:1:2", "other:42:1"] {
            XCTAssertNil(IncomingCallNotifications.callBack(identifier: identifier), identifier)
        }
    }
}
