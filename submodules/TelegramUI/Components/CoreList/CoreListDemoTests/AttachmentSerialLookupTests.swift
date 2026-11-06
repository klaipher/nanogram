import XCTest
@testable import CoreListDemo

/// `resolveAttachments` no longer hashes the whole collection per window change. These tests pin the
/// narrowed lookup against the full identity map on randomized collections and windows.
final class AttachmentSerialLookupTests: XCTestCase {
    private func makeItems(count: Int, groupSize: Int, idOffset: Int = 0) -> [CoreListItem] {
        (0..<count).map { index in
            AttachedItem(id: index + idOffset,
                         attachedItems: [AnyHashable("k\(index / groupSize)"): FixedHeightAttachment(label: "g")])
        }
    }

    private func priorRuns(from items: [CoreListItem], loaded: Range<Int>, serialBase: UInt64)
        -> (runs: [AttachmentRuns.PriorRun], attachments: [CoreVirtualListView.Window.Attachment]) {
        let pending = AttachmentRuns.pendingRuns(in: items, loadedRange: loaded)
        var runs: [AttachmentRuns.PriorRun] = []
        var attachments: [CoreVirtualListView.Window.Attachment] = []
        for (i, run) in pending.enumerated() {
            let serial = serialBase + UInt64(i)
            runs.append(AttachmentRuns.PriorRun(key: run.key,
                                                serial: serial,
                                                memberIdentities: run.memberRange.map { items[$0].identity },
                                                edge: run.edge))
            attachments.append(CoreVirtualListView.Window.Attachment(
                key: run.key,
                serial: serial,
                view: FixedHeightAttachmentView(height: 20),
                memberRange: run.memberRange,
                measuredHeight: 20,
                placement: run.placement,
                edge: run.edge,
                isFloating: run.isFloating,
                startsCollectionRun: run.startsCollectionRun,
                endsCollectionRun: run.endsCollectionRun,
                stackingGroup: nil,
                stackingYield: nil,
                bandTop: 0,
                bandBottom: 0))
        }
        return (runs, attachments)
    }

    private func summary(_ result: (assigned: [AttachmentRuns.ResolvedRun], departed: [AttachmentRuns.PriorRun]),
                         next: UInt64) -> String {
        let assigned = result.assigned.map { "\($0.key)|\($0.memberRange)|\($0.serial)|\($0.isFresh)" }
        let departed = result.departed.map { "\($0.serial)" }
        return "\(assigned)#\(departed)#\(next)"
    }

    private func randomLoaded(_ rng: inout SeededRNG, count: Int) -> Range<Int> {
        let lo = rng.int(in: 0..<count)
        let hi = rng.int(in: (lo + 1)..<(count + 1))
        return lo..<hi
    }

    func testClosureOverloadMatchesArrayOverload() {
        var rng = SeededRNG(seed: 0xA77A_0001)
        for _ in 0..<300 {
            let count = rng.int(in: 2..<60)
            let groupSize = rng.int(in: 1..<8)
            let oldItems = makeItems(count: count, groupSize: groupSize)
            let newItems = makeItems(count: count + rng.int(in: 0..<4), groupSize: groupSize,
                                     idOffset: rng.int(in: 0..<3))
            let (prior, _) = priorRuns(from: oldItems, loaded: randomLoaded(&rng, count: count), serialBase: 100)
            let pending = AttachmentRuns.pendingRuns(in: newItems,
                                                     loadedRange: randomLoaded(&rng, count: newItems.count))
            var byArray: UInt64 = 500
            let reference = AttachmentRuns.assignSerials(pending: pending,
                                                         newIdentities: newItems.map(\.identity),
                                                         prior: prior,
                                                         nextSerial: &byArray)
            var full: [AnyHashable: Int] = [:]
            for (i, item) in newItems.enumerated() { full[item.identity] = i }
            var byClosure: UInt64 = 500
            let actual = AttachmentRuns.assignSerials(pending: pending,
                                                      newIndexOfIdentity: { full[$0] },
                                                      prior: prior,
                                                      nextSerial: &byClosure)
            XCTAssertEqual(summary(actual, next: byClosure), summary(reference, next: byArray))
        }
    }

    /// The scroll case: collection unchanged, window moves. The narrowed lookup must exist and give
    /// the same serial assignment as the full map.
    func testSameIndexLookupMatchesFullMapWhenCollectionIsUnchanged() {
        var rng = SeededRNG(seed: 0xA77A_0002)
        for _ in 0..<300 {
            let count = rng.int(in: 2..<80)
            let items = makeItems(count: count, groupSize: rng.int(in: 1..<8))
            let (prior, attachments) = priorRuns(from: items, loaded: randomLoaded(&rng, count: count), serialBase: 100)
            let pending = AttachmentRuns.pendingRuns(in: items, loadedRange: randomLoaded(&rng, count: count))

            guard let lookup = CoreVirtualListView.sameIndexLookup(for: attachments,
                                                                  priorItems: items,
                                                                  currentItems: items) else {
                return XCTFail("unchanged collection must take the narrowed path")
            }
            var byArray: UInt64 = 500
            let reference = AttachmentRuns.assignSerials(pending: pending,
                                                         newIdentities: items.map(\.identity),
                                                         prior: prior,
                                                         nextSerial: &byArray)
            var byLookup: UInt64 = 500
            let actual = AttachmentRuns.assignSerials(pending: pending,
                                                      newIndexOfIdentity: { lookup[$0] },
                                                      prior: prior,
                                                      nextSerial: &byLookup)
            XCTAssertEqual(summary(actual, next: byLookup), summary(reference, next: byArray))
            // The lookup holds exactly the prior members, nothing like the whole collection.
            XCTAssertLessThanOrEqual(lookup.count, prior.reduce(0) { $0 + $1.memberIdentities.count })
        }
    }

    func testSameIndexLookupFallsBackWhenAMemberMoved() {
        let items = makeItems(count: 10, groupSize: 3)
        let (_, attachments) = priorRuns(from: items, loaded: 0..<10, serialBase: 1)
        // A new row at the front shifts every member by one.
        let shifted = [AttachedItem(id: 999)] + items
        XCTAssertNil(CoreVirtualListView.sameIndexLookup(for: attachments, priorItems: items, currentItems: shifted))
        // The collection got shorter than a member index.
        XCTAssertNil(CoreVirtualListView.sameIndexLookup(for: attachments, priorItems: items,
                                                         currentItems: Array(items.prefix(4))))
    }

    func testSameIndexLookupWithNoAttachmentsIsEmptyNotNil() {
        let items = makeItems(count: 3, groupSize: 1)
        XCTAssertEqual(CoreVirtualListView.sameIndexLookup(for: [], priorItems: items, currentItems: items)?.count, 0)
    }
}
