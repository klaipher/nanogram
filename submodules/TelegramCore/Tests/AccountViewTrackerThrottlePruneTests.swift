import XCTest
import Postbox
@testable import TelegramCore

final class AccountViewTrackerThrottlePruneTests: XCTestCase {
    func testRecordsOlderThanEveryThrottleWindowAreDropped() {
        let now: Int32 = 1_000_000_000
        var records: [MessageId: Int32] = [:]
        let peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(1))
        for i in 0 ..< 100_000 {
            let age = Int32((i % 24) * 60 * 60)
            records[MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(i))] = now - age
        }
        let pruned = prunedAccountViewTrackerThrottleRecords(records, now: now)
        XCTAssertEqual(pruned.count, records.filter { now - $0.value <= accountViewTrackerThrottleRetention }.count)
        XCTAssertLessThan(pruned.count, records.count)
        XCTAssertTrue(pruned.values.allSatisfy { now - $0 <= 11 * 60 * 60 })
    }

    func testTheRetentionOutlastsTheLongestThrottleWindow() {
        XCTAssertGreaterThan(accountViewTrackerThrottleRetention, 10 * 60 * 60)
    }
}
