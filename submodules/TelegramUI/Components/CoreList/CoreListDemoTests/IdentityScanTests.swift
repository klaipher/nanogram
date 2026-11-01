import XCTest
@testable import CoreListDemo

/// `firstDuplicatePair` and `computeDiff` run on every `applyChanges` with items, which is every chat
/// history transaction. They must give exactly the answers of the original quadratic scans, kept
/// below as references, and stay linear in the item count.
final class IdentityScanTests: XCTestCase {
    /// Same shape as the chat backend's `CoreListEntryItem`: identity is an `AnyHashable` over a UInt32.
    private final class StableIdItem: CoreListItem {
        let stableId: UInt32
        var identity: AnyHashable { AnyHashable(stableId) }
        init(_ stableId: UInt32) { self.stableId = stableId }
        func view() -> UIView & CoreListItemView { FixedHeightItemView(height: 10) }
        func isEqual(to other: CoreListItem) -> Bool { (other as? StableIdItem)?.stableId == stableId }
    }

    private func items(_ ids: [UInt32]) -> [CoreListItem] { ids.map { StableIdItem($0) } }

    // MARK: - References (the original O(n^2) scans)

    private static func referenceFirstDuplicatePair(in items: [CoreListItem]) -> (first: Int, second: Int)? {
        for first in items.indices {
            for second in items.indices where second > first {
                if items[first].identity == items[second].identity {
                    return (first, second)
                }
            }
        }
        return nil
    }

    private static func referenceSurvivorsAndInserts(old: [CoreListItem], new: [CoreListItem]) -> ([Int: Int], [Int]) {
        var oldMatched = Array(repeating: false, count: old.count)
        var survivorMap: [Int: Int] = [:]
        var inserts: [Int] = []
        for newIndex in new.indices {
            var matched = false
            for oldIndex in old.indices where !oldMatched[oldIndex] {
                if old[oldIndex].identity == new[newIndex].identity {
                    oldMatched[oldIndex] = true
                    survivorMap[oldIndex] = newIndex
                    matched = true
                    break
                }
            }
            if !matched { inserts.append(newIndex) }
        }
        return (survivorMap, inserts)
    }

    // MARK: - firstDuplicatePair

    func test_firstDuplicatePair_returnsTheLowestFirstIndexThenTheLowestSecond() {
        // A B B A: the pair with the lowest first index is (0, 3), not (1, 2), which a scan finds first.
        let pair = CoreVirtualListView.firstDuplicatePair(in: items([1, 2, 2, 1]))
        XCTAssertEqual(pair?.first, 0)
        XCTAssertEqual(pair?.second, 3)

        let triple = CoreVirtualListView.firstDuplicatePair(in: items([5, 7, 5, 5]))
        XCTAssertEqual(triple?.first, 0)
        XCTAssertEqual(triple?.second, 2)

        XCTAssertNil(CoreVirtualListView.firstDuplicatePair(in: items([])))
        XCTAssertNil(CoreVirtualListView.firstDuplicatePair(in: items([1])))
        XCTAssertNil(CoreVirtualListView.firstDuplicatePair(in: items([1, 2, 3])))
    }

    func test_firstDuplicatePair_matchesTheReferenceOnRandomInput() {
        var rng = SeededRNG(seed: 0x5eed)
        for _ in 0 ..< 400 {
            let count = Int.random(in: 0 ... 24, using: &rng)
            let ids = (0 ..< count).map { _ in UInt32.random(in: 0 ... 30, using: &rng) }
            let list = items(ids)
            let expected = Self.referenceFirstDuplicatePair(in: list)
            let actual = CoreVirtualListView.firstDuplicatePair(in: list)
            XCTAssertEqual(actual?.first, expected?.first, "ids \(ids)")
            XCTAssertEqual(actual?.second, expected?.second, "ids \(ids)")
        }
    }

    // MARK: - computeDiff

    func test_computeDiff_matchesTheReferenceOnRandomInput_includingDuplicateOldIdentities() {
        var rng = SeededRNG(seed: 0xd1ff)
        for _ in 0 ..< 400 {
            let oldIds = (0 ..< Int.random(in: 0 ... 20, using: &rng)).map { _ in UInt32.random(in: 0 ... 25, using: &rng) }
            let newIds = (0 ..< Int.random(in: 0 ... 20, using: &rng)).map { _ in UInt32.random(in: 0 ... 25, using: &rng) }
            let old = items(oldIds)
            let new = items(newIds)
            let (survivors, inserts) = Self.referenceSurvivorsAndInserts(old: old, new: new)
            let diff = CoreVirtualListView.computeDiff(old: old, new: new)
            // The LIS reclassification after the match is unchanged, so check the whole result by
            // re-deriving it: every survivor kept by the diff is a reference survivor, and every
            // reference survivor the diff dropped became a move.
            for (oldIndex, newIndex) in diff.survivorMap {
                XCTAssertEqual(survivors[oldIndex], newIndex, "old \(oldIds) new \(newIds)")
            }
            for move in diff.moves {
                XCTAssertEqual(survivors[move.old], move.new, "old \(oldIds) new \(newIds)")
            }
            XCTAssertEqual(diff.survivorMap.count + diff.moves.count, survivors.count, "old \(oldIds) new \(newIds)")
            XCTAssertEqual(Set(diff.inserts), Set(inserts + diff.moves.map(\.new)), "old \(oldIds) new \(newIds)")
            XCTAssertEqual(diff.inserts, diff.inserts.sorted())
        }
    }

    // MARK: - Cost

    /// Prints the cost of both scans for a chat-sized window. Not an assertion on time (machines
    /// differ), only that a 1000-row list stays far below one 120 Hz frame.
    func test_identityScans_costForChatSizedLists() {
        func measureMs(_ body: () -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 5 {
                let start = CACurrentMediaTime()
                body()
                best = min(best, (CACurrentMediaTime() - start) * 1000.0)
            }
            return best
        }
        for count: UInt32 in [100, 200, 400, 1000] {
            let old = items((0 ..< count).map { $0 + 100 })
            // Loading older history: 50 rows prepended, the rest survive.
            let new = items(Array(0 ..< UInt32(50)) + (0 ..< count).map { $0 + 100 })
            let duplicateMs = measureMs { _ = CoreVirtualListView.firstDuplicatePair(in: new) }
            let diffMs = measureMs { _ = CoreVirtualListView.computeDiff(old: old, new: new) }
            // The original quadratic scans, for the before/after numbers.
            let referenceDuplicateMs = measureMs { _ = IdentityScanTests.referenceFirstDuplicatePair(in: new) }
            let referenceDiffMs = measureMs { _ = IdentityScanTests.referenceSurvivorsAndInserts(old: old, new: new) }
            print("IdentityScanTests: n=\(new.count) firstDuplicatePair \(String(format: "%.3f", duplicateMs)) ms (quadratic \(String(format: "%.3f", referenceDuplicateMs)) ms), computeDiff \(String(format: "%.3f", diffMs)) ms (quadratic survivor scan \(String(format: "%.3f", referenceDiffMs)) ms)")
            if count == 1000 {
                XCTAssertLessThan(duplicateMs, 8.0)
                XCTAssertLessThan(diffMs, 8.0)
            }
        }
    }
}
