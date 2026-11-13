import XCTest
import NotificationsPresentationData
@testable import NotificationServiceExtensionLib

final class IncomingCallNotificationRoutingTests: XCTestCase {
    private func delivered(_ identifier: String, accountId: Int64, peerId: Int64) -> (identifier: String, userInfo: [AnyHashable: Any]) {
        return (identifier, IncomingCallPushPresentation.userInfo(accountId: accountId, peerId: peerId, fromUserId: peerId))
    }

    // A ring goes only for its own caller on its own account.
    func testIdentifiersAreForTheCallerOfTheAccount() {
        let items = [
            self.delivered("a", accountId: 1, peerId: 100),
            self.delivered("b", accountId: 2, peerId: 100),
            self.delivered("c", accountId: 1, peerId: 200),
            ("message", ["accountId": "1", "peerId": "100"] as [AnyHashable: Any])
        ]
        XCTAssertEqual(IncomingCallNotificationRouting.identifiers(delivered: items, accountId: 1, peerId: 100), ["a"])
        XCTAssertEqual(IncomingCallNotificationRouting.identifiers(delivered: items, accountId: 2, peerId: 100), ["b"])
        XCTAssertEqual(IncomingCallNotificationRouting.identifiers(delivered: items, accountId: 3, peerId: 100), [])
    }

    func testStaleRingsAreThoseOlderThanAnyCallRings() {
        let now = Date(timeIntervalSince1970: 10_000)
        let items: [(identifier: String, userInfo: [AnyHashable: Any], date: Date)] = [
            ("fresh", IncomingCallPushPresentation.markerUserInfo, now.addingTimeInterval(-30)),
            ("stale", IncomingCallPushPresentation.markerUserInfo, now.addingTimeInterval(-91)),
            ("message", ["peerId": "1"], now.addingTimeInterval(-500))
        ]
        XCTAssertEqual(IncomingCallNotifications.staleIdentifiers(delivered: items, now: now), ["stale"])
        XCTAssertEqual(IncomingCallNotifications.ringTimeout, 90.0)
    }

    func testKeysAreTheVoipPayloadKeys() {
        XCTAssertEqual(IncomingCallNotificationRouting.Key.callId, "call_id")
        XCTAssertEqual(IncomingCallNotificationRouting.Key.callAccessHash, "call_ah")
        XCTAssertEqual(IncomingCallNotificationRouting.Key.updates, "updates")
        XCTAssertEqual(IncomingCallNotificationRouting.Key.fromId, "from_id")
        XCTAssertEqual(IncomingCallNotificationRouting.Key.accountId, "accountId")
    }
}
