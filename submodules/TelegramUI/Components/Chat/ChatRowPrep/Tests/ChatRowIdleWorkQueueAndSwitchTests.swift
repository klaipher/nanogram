import Foundation
import XCTest
@testable import ChatRowPrep

final class ChatRowIdleWorkQueueTests: XCTestCase {
    func testWorkIsDeferredUntilRun() {
        let queue = ChatRowIdleWorkQueue(budget: 1.0)
        var ran = 0
        queue.enqueue { ran += 1 }
        XCTAssertEqual(ran, 0, "enqueue must not run the work inside the caller's frame")
        XCTAssertTrue(queue.isObserving)
        queue.runPending()
        XCTAssertEqual(ran, 1)
        XCTAssertFalse(queue.isObserving, "no observer without work")
    }

    func testTheBudgetSplitsWorkAcrossRuns() {
        var now: TimeInterval = 0.0
        let queue = ChatRowIdleWorkQueue(budget: 0.002, clock: { now })
        var order: [Int] = []
        for index in 0 ..< 3 {
            queue.enqueue {
                order.append(index)
                now += 0.003
            }
        }
        XCTAssertTrue(queue.runPending())
        XCTAssertEqual(order, [0], "at least one item, then stop once the budget is spent")
        XCTAssertTrue(queue.runPending())
        XCTAssertFalse(queue.runPending())
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testFlushRunsEverythingInOrder() {
        let queue = ChatRowIdleWorkQueue(budget: 0.0)
        var order: [Int] = []
        for index in 0 ..< 4 {
            queue.enqueue { order.append(index) }
        }
        queue.flush()
        XCTAssertEqual(order, [0, 1, 2, 3])
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertFalse(queue.isObserving)
    }

    func testCancelAllDropsWork() {
        let queue = ChatRowIdleWorkQueue()
        var ran = false
        queue.enqueue { ran = true }
        queue.cancelAll()
        queue.flush()
        XCTAssertFalse(ran)
    }

    func testTheRunLoopRunsQueuedWorkWhenItGoesIdle() {
        let queue = ChatRowIdleWorkQueue(budget: 1.0)
        let ran = expectation(description: "ran at idle")
        queue.enqueue { ran.fulfill() }
        wait(for: [ran], timeout: 2.0)
    }
}

final class ChatScrollExperimentsTests: XCTestCase {
    override func tearDown() {
        ChatScrollExperiments.setMask(0)
        super.tearDown()
    }

    func testBothSwitchesAreOffByDefault() {
        XCTAssertEqual(ChatScrollExperiments.mask, 0)
        XCTAssertFalse(ChatScrollExperiments.isPrepareLayoutAheadEnabled)
        XCTAssertFalse(ChatScrollExperiments.isReuseRowViewsEnabled)
    }

    func testEachBitDrivesItsOwnFlag() {
        ChatScrollExperiments.setMask(ChatScrollExperiment.prepareLayoutAhead.rawValue)
        XCTAssertTrue(ChatScrollExperiments.isPrepareLayoutAheadEnabled)
        XCTAssertFalse(ChatScrollExperiments.isReuseRowViewsEnabled)
        ChatScrollExperiments.setMask(ChatScrollExperiment.reuseRowViews.rawValue)
        XCTAssertFalse(ChatScrollExperiments.isPrepareLayoutAheadEnabled)
        XCTAssertTrue(ChatScrollExperiments.isReuseRowViewsEnabled)
        ChatScrollExperiments.setMask(0)
        XCTAssertFalse(ChatScrollExperiments.isReuseRowViewsEnabled)
    }

    func testUnknownBitsAreDropped() {
        ChatScrollExperiments.setMask(0x7ffffff0 | ChatScrollExperiment.reuseRowViews.rawValue)
        XCTAssertEqual(ChatScrollExperiments.mask, ChatScrollExperiment.reuseRowViews.rawValue)
    }

    func testMaskHelpers() {
        var mask = ChatScrollExperiments.mask(0, setting: .prepareLayoutAhead, enabled: true)
        mask = ChatScrollExperiments.mask(mask, setting: .reuseRowViews, enabled: true)
        XCTAssertEqual(mask, ChatScrollExperiments.mask(of: [.prepareLayoutAhead, .reuseRowViews]))
        XCTAssertEqual(ChatScrollExperiments.mask(mask, setting: .prepareLayoutAhead, enabled: false), ChatScrollExperiment.reuseRowViews.rawValue)
    }
}
