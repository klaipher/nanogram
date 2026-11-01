import Foundation
import XCTest
@testable import Postbox

/// Unread counts are server Int32 values. Summing them across namespaces, or adding new
/// incoming messages to a count near Int32.max, trapped inside a Postbox transaction.
final class PeerReadStateOverflowTests: XCTestCase {
    private func state(count: Int32) -> PeerReadState {
        return .idBased(maxIncomingReadId: 1, maxOutgoingReadId: 1, maxKnownId: 1, count: count, markedUnread: false)
    }

    func testCombinedCountSaturates() {
        let combined = CombinedPeerReadState(states: [(0, self.state(count: Int32.max)), (1, self.state(count: Int32.max)), (2, self.state(count: 5))])
        XCTAssertEqual(combined.count, Int32.max)
        let negative = CombinedPeerReadState(states: [(0, self.state(count: Int32.min)), (1, self.state(count: -1))])
        XCTAssertEqual(negative.count, Int32.min)
        let ordinary = CombinedPeerReadState(states: [(0, self.state(count: 3)), (1, self.state(count: 4))])
        XCTAssertEqual(ordinary.count, 7)
    }

    func testAddedCountSaturates() {
        XCTAssertEqual(self.state(count: Int32.max).withAddedCount(1).count, Int32.max)
        XCTAssertEqual(self.state(count: Int32.max - 1).withAddedCount(Int32.max).count, Int32.max)
        XCTAssertEqual(self.state(count: Int32.min).withAddedCount(-1).count, Int32.min)
        XCTAssertEqual(self.state(count: 10).withAddedCount(-3).count, 7)
        let indexBased: PeerReadState = .indexBased(maxIncomingReadIndex: MessageIndex.absoluteLowerBound(), maxOutgoingReadIndex: MessageIndex.absoluteLowerBound(), count: Int32.max, markedUnread: false)
        XCTAssertEqual(indexBased.withAddedCount(Int32.max).count, Int32.max)
    }

    func testCounterHelpers() {
        XCTAssertEqual(clampedUnreadCountSum(Int32.max, 1), Int32.max)
        XCTAssertEqual(clampedUnreadCountSum(Int32.min, -1), Int32.min)
        XCTAssertEqual(clampedUnreadCountSum(2, 3), 5)
        XCTAssertEqual(clampedUnreadCountNegation(Int32.min), Int32.max)
        XCTAssertEqual(clampedUnreadCountNegation(5), -5)
        var counters = PeerGroupUnreadCounters(messageCount: Int32.max - 1, chatCount: 1)
        counters.addMessageCount(Int32.max)
        XCTAssertEqual(counters.messageCount, Int32.max)
    }
}
