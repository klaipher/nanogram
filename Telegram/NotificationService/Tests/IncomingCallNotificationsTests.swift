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

    // The call back is placed from the account the call came to while that account is still
    // signed in here; a handle donated before it signed out (or was removed) is dropped rather than
    // making a missing account record the current one.
    func testCallBackOnlyFromASignedInAccount() {
        let callBack = IncomingCallNotifications.CallBack(accountId: 42, peerId: 1234)
        XCTAssertEqual(IncomingCallNotifications.callBackAccountId(callBack, accounts: [(id: 7, isLoggedOut: false), (id: 42, isLoggedOut: false)]), 42)
        XCTAssertNil(IncomingCallNotifications.callBackAccountId(callBack, accounts: [(id: 7, isLoggedOut: false), (id: 42, isLoggedOut: true)]))
        XCTAssertNil(IncomingCallNotifications.callBackAccountId(callBack, accounts: [(id: 7, isLoggedOut: false)]))
        XCTAssertNil(IncomingCallNotifications.callBackAccountId(callBack, accounts: []))
    }

    // Handles that are not the extension's (Siri, the system's call history, the older "tg<peer>"
    // custom identifiers and bare peer ids) are left to the existing call-back paths.
    func testOtherHandlesAreNotCallBacks() {
        for identifier in ["1234", "tg1234", "+15551234567", "", "nanogram-call:", "nanogram-call:42", "nanogram-call:42:x", "nanogram-call:42:1:2", "other:42:1"] {
            XCTAssertNil(IncomingCallNotifications.callBack(identifier: identifier), identifier)
        }
    }

    // MARK: - Ending a ring

    func testMissedCallPushesEndTheRing() {
        for key in ["PHONE_CALL_MISSED", "VIDEO_CALL_MISSED", "CONF_CALL_MISSED"] {
            XCTAssertTrue(IncomingCallNotifications.endsRing(locKey: key), key)
        }
        for key in ["PHONE_CALL_REQUEST", "MESSAGE_TEXT", "READ_HISTORY", ""] {
            XCTAssertFalse(IncomingCallNotifications.endsRing(locKey: key), key)
        }
        XCTAssertFalse(IncomingCallNotifications.endsRing(locKey: nil))
    }

    func testCallRelatedPushesAreLogged() {
        XCTAssertTrue(IncomingCallNotifications.isCallRelated(locKey: "PHONE_CALL_REQUEST"))
        XCTAssertTrue(IncomingCallNotifications.isCallRelated(locKey: "VIDEO_CALL_MISSED"))
        XCTAssertTrue(IncomingCallNotifications.isCallRelated(locKey: "CONF_VIDEOCALL_REQUEST"))
        XCTAssertFalse(IncomingCallNotifications.isCallRelated(locKey: "MESSAGE_TEXT"))
        XCTAssertFalse(IncomingCallNotifications.isCallRelated(locKey: nil))
    }

    // The ringtone lasts 30 s, so watching longer than that only wastes the extension's budget.
    func testWatchPolicy() {
        XCTAssertEqual(IncomingCallNotifications.ringWatchWindow, 30.0)
        XCTAssertEqual(IncomingCallNotifications.ringWatchInterval, 2.0)
        XCTAssertLessThan(IncomingCallNotifications.ringWatchWindow, IncomingCallNotifications.ringTimeout)
    }

    func testPushActions() {
        XCTAssertEqual(IncomingCallNotifications.pushAction(locKey: "PHONE_CALL_REQUEST", callId: 5, deliveredRingCallIds: []), .ring)
        XCTAssertEqual(IncomingCallNotifications.pushAction(locKey: "PHONE_CALL_REQUEST", callId: 5, deliveredRingCallIds: [4, 5]), .showQuietly)
        XCTAssertEqual(IncomingCallNotifications.pushAction(locKey: "PHONE_CALL_REQUEST", callId: 6, deliveredRingCallIds: [5]), .ring)
        XCTAssertEqual(IncomingCallNotifications.pushAction(locKey: "PHONE_CALL_MISSED", callId: nil, deliveredRingCallIds: [5]), .stopRinging)
        XCTAssertEqual(IncomingCallNotifications.pushAction(locKey: "MESSAGE_TEXT", callId: nil, deliveredRingCallIds: [5]), .ignore)
    }

    // The stop path finds the ring by the call id in its userInfo, not by its APNs identifier.
    func testRingIsFoundByCallId() {
        func ring(_ id: String, accountId: Int64, callId: Int64) -> (identifier: String, userInfo: [AnyHashable: Any]) {
            let call = IncomingCallNotificationRouting.Call(accountId: accountId, peerId: 100, fromId: 100, callId: callId, accessHash: 1, updates: "u", isVideo: false)
            return (id, IncomingCallPushPresentation.userInfo(accountId: accountId, peerId: 100, fromUserId: 100, call: call))
        }
        let delivered = [
            ring("a", accountId: 7, callId: 1),
            ring("b", accountId: 7, callId: 2),
            ring("c", accountId: 8, callId: 1),
            (identifier: "message", userInfo: ["call_id": "1", "accountId": "7"] as [AnyHashable: Any])
        ]
        XCTAssertEqual(IncomingCallNotificationRouting.identifiers(delivered: delivered, accountId: 7, callId: 1), ["a"])
        XCTAssertEqual(IncomingCallNotificationRouting.identifiers(delivered: delivered, accountId: 8, callId: 1), ["c"])
        XCTAssertEqual(IncomingCallNotificationRouting.identifiers(delivered: delivered, accountId: 7, callId: 3), [])
        XCTAssertEqual(IncomingCallNotificationRouting.callIds(delivered: delivered, accountId: 7).sorted(), [1, 2])
    }
}
