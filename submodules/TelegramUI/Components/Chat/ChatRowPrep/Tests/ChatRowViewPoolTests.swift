import XCTest
@testable import ChatRowPrep

final class ChatRowViewPoolTests: XCTestCase {
    final class FakeView {
        var dirty = true
        var resets = 0
        var refuses = false
    }

    private func makePool(perKind: Int = 2, total: Int = 3) -> (ChatRowViewPool<FakeView, String>, Box) {
        let box = Box()
        let pool = ChatRowViewPool<FakeView, String>(limits: .init(perKind: perKind, total: total), reset: { view in
            view.resets += 1
            if view.refuses {
                return false
            }
            view.dirty = false
            return true
        })
        pool.onDiscard = { box.discarded.append($0) }
        return (pool, box)
    }

    final class Box {
        var discarded: [FakeView] = []
    }

    func testAViewIsResetWhenRecycledAndHandedOutByKind() {
        let (pool, _) = self.makePool()
        let view = FakeView()
        XCTAssertTrue(pool.recycle(view, kind: "sticker"))
        XCTAssertFalse(view.dirty)
        XCTAssertNil(pool.obtain(kind: "bubble"))
        XCTAssertTrue(pool.obtain(kind: "sticker") === view)
        XCTAssertNil(pool.obtain(kind: "sticker"))
        XCTAssertEqual(pool.reuseCount, 1)
        XCTAssertEqual(pool.missCount, 2)
    }

    func testAViewThatCannotBeResetIsNotPooled() {
        let (pool, box) = self.makePool()
        let view = FakeView()
        view.refuses = true
        XCTAssertFalse(pool.recycle(view, kind: "sticker"))
        XCTAssertEqual(pool.count, 0)
        XCTAssertTrue(box.discarded.first === view)
    }

    func testThePerKindCapDropsTheOldest() {
        let (pool, box) = self.makePool(perKind: 2, total: 10)
        let a = FakeView(), b = FakeView(), c = FakeView()
        pool.recycle(a, kind: "k")
        pool.recycle(b, kind: "k")
        pool.recycle(c, kind: "k")
        XCTAssertEqual(pool.count(of: "k"), 2)
        XCTAssertTrue(box.discarded.first === a)
        XCTAssertTrue(pool.obtain(kind: "k") === c)
    }

    func testTheTotalCapDropsTheOldestOfAnyKind() {
        let (pool, box) = self.makePool(perKind: 5, total: 3)
        let views = (0 ..< 4).map { _ in FakeView() }
        for (index, view) in views.enumerated() {
            pool.recycle(view, kind: index % 2 == 0 ? "a" : "b")
        }
        XCTAssertEqual(pool.count, 3)
        XCTAssertTrue(box.discarded.first === views[0])
    }

    func testDrainEmptiesThePool() {
        let (pool, box) = self.makePool()
        pool.recycle(FakeView(), kind: "a")
        pool.recycle(FakeView(), kind: "b")
        pool.drain()
        XCTAssertEqual(pool.count, 0)
        XCTAssertEqual(box.discarded.count, 2)
        XCTAssertNil(pool.obtain(kind: "a"))
    }

    func testAZeroCapPoolKeepsNothing() {
        let (pool, _) = self.makePool(perKind: 0, total: 0)
        XCTAssertFalse(pool.recycle(FakeView(), kind: "a"))
        XCTAssertEqual(pool.count, 0)
    }
}
