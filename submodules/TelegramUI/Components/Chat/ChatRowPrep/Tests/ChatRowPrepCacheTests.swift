import Foundation
import XCTest
@testable import ChatRowPrep

final class ChatRowPrepCacheTests: XCTestCase {
    typealias Key = ChatRowPrepKey<Int>
    typealias Cache = ChatRowPrepCache<Int, String>

    private let item = NSObject()
    private let theme = NSObject()
    private var time: TimeInterval = 100.0

    private func key(_ id: UInt64, version: Int = 1, width: CGFloat = 390.0, neighbors: Int = 0, epoch: UInt64 = 0, font: Int32 = 16) -> Key {
        return Key(stableId: id, stableVersion: version, itemToken: ObjectIdentifier(self.item), width: width, leftInset: 0.0, rightInset: 0.0, neighbors: neighbors, themeToken: ObjectIdentifier(self.theme), fontSize: font, interactionEpoch: epoch, rotated: true, synchronousLoads: false)
    }

    private func makeCache(maxEntries: Int = 10, ttl: TimeInterval = 5.0) -> (Cache, Discards) {
        let discards = Discards()
        let cache = Cache(limits: Cache.Limits(maxEntries: maxEntries, timeToLive: ttl), now: { [unowned self] in self.time })
        cache.onDiscard = { discards.values.append($0) }
        return (cache, discards)
    }

    final class Discards {
        var values: [String] = []
    }

    private func prepare(_ cache: Cache, _ key: Key, payload: String) {
        guard case let .started(ticket) = cache.claim(key) else {
            XCTFail("claim refused")
            return
        }
        XCTAssertTrue(cache.complete(ticket: ticket, key: key, payload: payload))
    }

    func testExactKeyHitsOnceAndIsConsumed() {
        let (cache, _) = self.makeCache()
        self.prepare(cache, self.key(1), payload: "row1")
        guard case let .hit(payload) = cache.take(self.key(1)) else {
            XCTFail("expected a hit")
            return
        }
        XCTAssertEqual(payload, "row1")
        guard case .miss(.nothingPrepared) = cache.take(self.key(1)) else {
            XCTFail("a payload must not be used twice")
            return
        }
    }

    func testAStalePrefetchIsNeverUsed() {
        let changes: [(String, Key)] = [
            ("version", self.key(1, version: 2)),
            ("width", self.key(1, width: 320.0)),
            ("neighbors", self.key(1, neighbors: 1)),
            ("epoch", self.key(1, epoch: 1)),
            ("font", self.key(1, font: 17))
        ]
        for (name, changed) in changes {
            let (cache, discards) = self.makeCache()
            self.prepare(cache, self.key(1), payload: "row1")
            guard case .miss(.keyMismatch) = cache.take(changed) else {
                XCTFail("\(name): a result prepared under another key was used")
                continue
            }
            XCTAssertEqual(discards.values, ["row1"], name)
            XCTAssertEqual(cache.count, 0, name)
        }
    }

    func testADifferentItemInstanceIsAMiss() {
        let (cache, _) = self.makeCache()
        self.prepare(cache, self.key(1), payload: "row1")
        var other = self.key(1)
        other.itemToken = ObjectIdentifier(NSObject())
        guard case .miss(.keyMismatch) = cache.take(other) else {
            XCTFail("item instance must be part of the match")
            return
        }
    }

    func testAnInFlightRowIsAMissAndItsLateResultIsRejected() {
        let (cache, discards) = self.makeCache()
        guard case let .started(ticket) = cache.claim(self.key(1)) else {
            XCTFail()
            return
        }
        guard case .miss(.inFlight) = cache.take(self.key(1)) else {
            XCTFail()
            return
        }
        XCTAssertTrue(ticket.isCancelled)
        XCTAssertFalse(cache.complete(ticket: ticket, key: self.key(1), payload: "late"))
        XCTAssertEqual(discards.values, ["late"])
        XCTAssertEqual(cache.count, 0)
    }

    func testClaimingTheSameKeyTwiceStartsOneJob() {
        let (cache, _) = self.makeCache()
        guard case .started = cache.claim(self.key(1)) else {
            XCTFail()
            return
        }
        guard case .alreadyPrepared = cache.claim(self.key(1)) else {
            XCTFail()
            return
        }
    }

    func testRetainCancelsAndEvictsRowsOutsideThePlan() {
        let (cache, discards) = self.makeCache()
        self.prepare(cache, self.key(1), payload: "row1")
        guard case let .started(ticket2) = cache.claim(self.key(2)) else {
            XCTFail()
            return
        }
        self.prepare(cache, self.key(3), payload: "row3")
        cache.retain(keys: [self.key(3)])
        XCTAssertTrue(ticket2.isCancelled)
        XCTAssertEqual(discards.values, ["row1"])
        XCTAssertEqual(cache.count, 1)
        XCTAssertFalse(cache.complete(ticket: ticket2, key: self.key(2), payload: "row2"))
        guard case .hit("row3") = cache.take(self.key(3)) else {
            XCTFail("row in the plan must survive")
            return
        }
    }

    func testRetainEvictsWhenWidthThemeOrFontChanged() {
        let (cache, discards) = self.makeCache()
        self.prepare(cache, self.key(1), payload: "a")
        self.prepare(cache, self.key(2), payload: "b")
        cache.retain(keys: [self.key(1, width: 320.0), self.key(2, font: 18)])
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(Set(discards.values), ["a", "b"])
    }

    func testEvictAllCancelsEveryTicket() {
        let (cache, _) = self.makeCache()
        guard case let .started(ticket) = cache.claim(self.key(1)) else {
            XCTFail()
            return
        }
        self.prepare(cache, self.key(2), payload: "b")
        cache.evictAll()
        XCTAssertTrue(ticket.isCancelled)
        XCTAssertEqual(cache.count, 0)
    }

    func testTheEntryLimitCapsMemory() {
        let (cache, _) = self.makeCache(maxEntries: 2)
        self.prepare(cache, self.key(1), payload: "a")
        self.prepare(cache, self.key(2), payload: "b")
        guard case .full = cache.claim(self.key(3)) else {
            XCTFail("a third row must be refused")
            return
        }
        XCTAssertEqual(cache.count, 2)
    }

    func testAResultOlderThanTheTimeToLiveIsNotUsed() {
        let (cache, discards) = self.makeCache(ttl: 5.0)
        self.prepare(cache, self.key(1), payload: "a")
        self.time += 5.5
        guard case .miss(.expired) = cache.take(self.key(1)) else {
            XCTFail()
            return
        }
        XCTAssertEqual(discards.values, ["a"])
    }

    func testFailRemovesTheClaim() {
        let (cache, _) = self.makeCache()
        guard case let .started(ticket) = cache.claim(self.key(1)) else {
            XCTFail()
            return
        }
        cache.fail(ticket: ticket, key: self.key(1))
        XCTAssertEqual(cache.count, 0)
    }

    func testAReplacedClaimCancelsTheOldTicket() {
        let (cache, _) = self.makeCache()
        guard case let .started(old) = cache.claim(self.key(1)) else {
            XCTFail()
            return
        }
        guard case let .started(new) = cache.claim(self.key(1, version: 2)) else {
            XCTFail()
            return
        }
        XCTAssertTrue(old.isCancelled)
        XCTAssertFalse(new.isCancelled)
        XCTAssertFalse(cache.complete(ticket: old, key: self.key(1), payload: "old"))
        XCTAssertTrue(cache.complete(ticket: new, key: self.key(1, version: 2), payload: "new"))
    }
}
