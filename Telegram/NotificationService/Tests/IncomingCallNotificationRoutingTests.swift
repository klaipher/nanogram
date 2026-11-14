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

    // A missed push for call 1 must be able to leave the ring of call 2 from the same caller: each ring is listed with its own call keys.
    func testCallsListsEachRingOfTheCallerWithItsOwnCallKeys() {
        func ring(_ identifier: String, callId: Int64, accessHash: Int64) -> (identifier: String, userInfo: [AnyHashable: Any]) {
            var userInfo = IncomingCallPushPresentation.userInfo(accountId: 1, peerId: 100, fromUserId: 100)
            userInfo[IncomingCallNotificationRouting.Key.callId] = "\(callId)"
            userInfo[IncomingCallNotificationRouting.Key.callAccessHash] = "\(accessHash)"
            return (identifier, userInfo)
        }
        let items = [
            ring("first", callId: 11, accessHash: 111),
            ring("second", callId: 22, accessHash: 222),
            self.delivered("withoutKeys", accountId: 1, peerId: 100),
            self.delivered("otherCaller", accountId: 1, peerId: 200)
        ]
        let calls = IncomingCallNotificationRouting.calls(delivered: items, accountId: 1, peerId: 100)
        XCTAssertEqual(calls.map { $0.identifier }, ["first", "second"])
        XCTAssertEqual(calls.map { $0.callId }, [11, 22])
        XCTAssertEqual(calls.map { $0.accessHash }, [111, 222])
        XCTAssertEqual(IncomingCallNotificationRouting.identifiers(delivered: items, accountId: 1, callId: 11), ["first"])
        XCTAssertTrue(IncomingCallNotificationRouting.calls(delivered: items, accountId: 2, peerId: 100).isEmpty)
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
