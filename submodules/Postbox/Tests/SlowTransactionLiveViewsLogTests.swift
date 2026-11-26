import Foundation
import XCTest
@testable import Postbox

/// The slow-transaction live-views diagnostic runs on the Postbox queue. It names view keys by their case only (no
/// payload is printed), counts each combined view's keys once, and is logged only for a long transaction, at most
/// once a minute.
final class SlowTransactionLiveViewsLogTests: XCTestCase {
    private let peerId = MessageHistoryTableFixture.peerId(700)

    func testKindIsTheCaseNameWithoutThePayload() {
        XCTAssertEqual(postboxViewKeyKind(.basicPeer(self.peerId)), "basicPeer")
        XCTAssertEqual(postboxViewKeyKind(.cachedPeerData(peerId: self.peerId)), "cachedPeerData")
        XCTAssertEqual(postboxViewKeyKind(.peer(peerId: self.peerId, components: [.cachedData, .subPeers])), "peer")
        XCTAssertEqual(postboxViewKeyKind(.peerPresences(peerIds: Set([self.peerId]))), "peerPresences")
    }

    func testKindOfACaseWithoutPayloadIsItsName() {
        XCTAssertEqual(postboxViewKeyKind(.additionalChatListItems), "additionalChatListItems")
        XCTAssertEqual(postboxViewKeyKind(.pendingPeerNotificationSettings), "pendingPeerNotificationSettings")
    }

    func testKindCountsAddUpPerKind() {
        let otherPeerId = MessageHistoryTableFixture.peerId(701)
        let keys: [PostboxViewKey] = [
            .basicPeer(self.peerId),
            .basicPeer(otherPeerId),
            .cachedPeerData(peerId: self.peerId),
            .additionalChatListItems
        ]
        XCTAssertEqual(postboxViewKeyKindCounts(keys), ["basicPeer": 2, "cachedPeerData": 1, "additionalChatListItems": 1])
        XCTAssertEqual(postboxViewKeyKindCounts([PostboxViewKey]()), [:])
    }

    func testKindCountsAreListedLargestFirstThenByName() {
        let description = postboxViewKindCountsDescription(["peer": 3, "basicPeer": 5, "cachedPeerData": 3])
        XCTAssertEqual(description, "basicPeer=5 cachedPeerData=3 peer=3")
    }

    func testOnlyTheLargestKindsAreListedAndTheRestIsSummed() {
        let counts = ["a": 1, "b": 2, "c": 3, "d": 4]
        XCTAssertEqual(postboxViewKindCountsDescription(counts, prefix: "combined.", limit: 2), "combined.d=4 combined.c=3 combined.others=3")
        XCTAssertEqual(postboxViewKindCountsDescription(counts, limit: 4), "d=4 c=3 b=2 a=1")
        XCTAssertEqual(postboxViewKindCountsDescription([:], limit: 2), "")
    }

    func testAShortTransactionIsNeverDescribed() {
        var log = SlowTransactionLiveViewsLog()
        XCTAssertFalse(log.shouldLog(transactionDuration: 0.06, now: 1000.0))
        XCTAssertFalse(log.shouldLog(transactionDuration: 0.099, now: 1000.0))
        XCTAssertTrue(log.shouldLog(transactionDuration: 0.1, now: 1000.0))
    }

    func testTheNextDescriptionComesAMinuteLater() {
        var log = SlowTransactionLiveViewsLog()
        XCTAssertTrue(log.shouldLog(transactionDuration: 0.2, now: 1000.0))
        XCTAssertFalse(log.shouldLog(transactionDuration: 0.5, now: 1030.0))
        XCTAssertFalse(log.shouldLog(transactionDuration: 0.5, now: 1059.9))
        XCTAssertTrue(log.shouldLog(transactionDuration: 0.5, now: 1060.0))
        XCTAssertFalse(log.shouldLog(transactionDuration: 0.5, now: 1061.0))
    }

    func testAShortTransactionDoesNotRestartTheMinute() {
        var log = SlowTransactionLiveViewsLog()
        XCTAssertTrue(log.shouldLog(transactionDuration: 0.2, now: 1000.0))
        XCTAssertFalse(log.shouldLog(transactionDuration: 0.02, now: 1070.0))
        XCTAssertTrue(log.shouldLog(transactionDuration: 0.2, now: 1071.0))
    }

    func testAClockGoingBackwardsDoesNotSilenceTheLog() {
        var log = SlowTransactionLiveViewsLog()
        XCTAssertTrue(log.shouldLog(transactionDuration: 0.2, now: 9000.0))
        XCTAssertTrue(log.shouldLog(transactionDuration: 0.2, now: 100.0))
        XCTAssertFalse(log.shouldLog(transactionDuration: 0.2, now: 110.0))
    }
}
