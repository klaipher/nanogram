import XCTest
import MergeLists

/// Diffing a chat list: 10000 rows against the same rows after 500 of them changed, 60 moved to the top and 30 were
/// removed, which is the shape of an update that arrives while the list is open. This is the `mergeListsStableWithUpdates`
/// call every chat list transition makes before it prepares any row. Measures wall clock, CPU and peak memory.
///
/// Skipped unless TG_PERF=1 (see Postbox/Tests/PostboxReadPerformanceTests.swift for how to run and compare).
final class ChatListDiffPerformanceTests: XCTestCase {
    private struct Row: Comparable, Identifiable {
        let stableId: Int
        let sortKey: Int
        let revision: Int

        static func < (lhs: Row, rhs: Row) -> Bool {
            return lhs.sortKey > rhs.sortKey
        }
    }

    private var before: [Row] = []
    private var after: [Row] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TG_PERF"] == "1", "performance tests run with TG_PERF=1 (tg perf run)")
        let count = 10000
        self.before = (0 ..< count).map { Row(stableId: $0, sortKey: count - $0, revision: 0) }
        var updated = self.before
        for index in stride(from: 0, to: count, by: 20) {
            updated[index] = Row(stableId: updated[index].stableId, sortKey: updated[index].sortKey, revision: 1)
        }
        for index in stride(from: 1, to: 60, by: 1) {
            updated[count - index] = Row(stableId: updated[count - index].stableId, sortKey: count + index, revision: 1)
        }
        for index in stride(from: 100, to: 400, by: 10) {
            updated.removeAll(where: { $0.stableId == index })
        }
        self.after = updated.sorted()
    }

    func testDiffChatListAfterAnUpdate() {
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        var inserted = 0
        self.measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let (removed, insertedItems, updatedItems) = mergeListsStableWithUpdates(leftList: self.before, rightList: self.after)
            inserted = removed.count + insertedItems.count + updatedItems.count
        }
        XCTAssertGreaterThan(inserted, 0)
    }
}
