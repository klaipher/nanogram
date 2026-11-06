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

final class ChatRowIdleWorkQueueOrderingTests: XCTestCase {
    func testTheObserverRunsAfterTheCoreAnimationCommit() {
        // UIKit's before-commit handler is near 1999000, the commit at 2000000 and its after-commit handler at 2001000.
        XCTAssertGreaterThan(ChatRowIdleWorkQueue.observerOrder, 2001000)
    }

    func testTheTurnThatQueuedTheWorkIsSkipped() {
        let queue = ChatRowIdleWorkQueue(budget: 1.0)
        var ran = 0
        queue.enqueue { ran += 1 }
        XCTAssertFalse(queue.idleTurn(), "the turn that queued the work only skips")
        XCTAssertEqual(ran, 0)
        XCTAssertTrue(queue.idleTurn(), "the following turn runs it")
        XCTAssertEqual(ran, 1)
        XCTAssertFalse(queue.isObserving)
    }

    func testQueuingAgainSkipsTheNextTurnAgain() {
        let queue = ChatRowIdleWorkQueue(budget: 1.0)
        var order: [Int] = []
        queue.enqueue { order.append(0) }
        XCTAssertFalse(queue.idleTurn())
        queue.enqueue { order.append(1) }
        XCTAssertFalse(queue.idleTurn(), "work queued in this turn waits for the next one")
        XCTAssertEqual(order, [])
        XCTAssertTrue(queue.idleTurn())
        XCTAssertEqual(order, [0, 1])
    }

    func testTheRealRunLoopRunsTheWorkOnALaterTurn() {
        let queue = ChatRowIdleWorkQueue(budget: 1.0)
        var queuedInTurn: Bool = true
        let ran = expectation(description: "ran")
        queue.enqueue {
            XCTAssertFalse(queuedInTurn, "must not run inside the turn that queued it")
            ran.fulfill()
        }
        DispatchQueue.main.async {
            queuedInTurn = false
        }
        wait(for: [ran], timeout: 2.0)
    }
}

final class ChatRowIdleWorkQueueCapTests: XCTestCase {
    func testTheQueueIsCappedAt16ByDefault() {
        let queue = ChatRowIdleWorkQueue()
        XCTAssertEqual(queue.maxPending, 16)
        for _ in 0 ..< 16 {
            XCTAssertTrue(queue.enqueue {})
        }
        XCTAssertFalse(queue.hasRoom())
        XCTAssertEqual(queue.pendingCount, 16)
        queue.cancelAll()
    }

    func testWorkBeyondTheCapIsRefusedNotQueued() {
        let queue = ChatRowIdleWorkQueue(maxPending: 2)
        var ran: [Int] = []
        XCTAssertTrue(queue.enqueue { ran.append(0) })
        XCTAssertTrue(queue.enqueue { ran.append(1) })
        XCTAssertFalse(queue.enqueue { ran.append(2) }, "the caller does this one itself")
        XCTAssertEqual(queue.pendingCount, 2)
        queue.flush()
        XCTAssertEqual(ran, [0, 1])
    }

    func testHasRoomCountsABatch() {
        let queue = ChatRowIdleWorkQueue(maxPending: 3)
        queue.enqueue {}
        XCTAssertTrue(queue.hasRoom(for: 2))
        XCTAssertFalse(queue.hasRoom(for: 3), "a batch that does not fit is refused as a whole")
        queue.cancelAll()
    }

    func testRoomComesBackWhenWorkRuns() {
        var now: TimeInterval = 0.0
        let queue = ChatRowIdleWorkQueue(budget: 0.002, maxPending: 2, clock: { now })
        queue.enqueue { now += 0.003 }
        queue.enqueue {}
        XCTAssertFalse(queue.hasRoom())
        queue.runPending()
        XCTAssertTrue(queue.hasRoom())
        queue.cancelAll()
    }
}

final class ChatRowPrepEpochTests: XCTestCase {
    func testAssigningTheSameValueDoesNotMoveTheEpoch() {
        var epoch = ChatRowPrepEpoch()
        epoch.noteAssignment(from: false, to: false)
        epoch.noteAssignment(from: Optional<Int>.none, to: nil)
        epoch.noteAssignment(from: Optional(7), to: 7)
        XCTAssertEqual(epoch.value, 0)
    }

    func testAScrollFrameThatReassignsAnUnchangedButtonStateKeepsTheEpoch() {
        var epoch = ChatRowPrepEpoch()
        var recommendedChannelsOpenUp = false
        for _ in 0 ..< 120 {
            let old = recommendedChannelsOpenUp
            recommendedChannelsOpenUp = false
            epoch.noteAssignment(from: old, to: recommendedChannelsOpenUp)
        }
        XCTAssertEqual(epoch.value, 0)
    }

    func testADifferentValueMovesTheEpochOnce() {
        var epoch = ChatRowPrepEpoch()
        epoch.noteAssignment(from: false, to: true)
        XCTAssertEqual(epoch.value, 1)
        epoch.noteAssignment(from: Optional(1), to: nil)
        XCTAssertEqual(epoch.value, 2)
        epoch.noteAssignment(from: Optional<Int>.none, to: 3)
        XCTAssertEqual(epoch.value, 3)
    }

    func testAnUncomparableChangeAlwaysMovesTheEpoch() {
        var epoch = ChatRowPrepEpoch()
        epoch.noteChange()
        epoch.noteChange()
        XCTAssertEqual(epoch.value, 2)
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
