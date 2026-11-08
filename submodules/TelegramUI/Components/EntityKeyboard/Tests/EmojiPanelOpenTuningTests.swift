import Foundation
import XCTest
@testable import EntityKeyboard

final class EmojiPanelOpenTuningTests: XCTestCase {
    func testHandoffIsDeferredOnlyWhenSwitchingIntoMediaWithoutAPanel() {
        XCTAssertTrue(DeferredKeyboardHandoffGate.shouldDefer(wasMedia: false, willBeMedia: true, panelAlreadyBuilt: false, hasCustomTextView: false))
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(wasMedia: true, willBeMedia: true, panelAlreadyBuilt: false, hasCustomTextView: false))
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(wasMedia: false, willBeMedia: false, panelAlreadyBuilt: false, hasCustomTextView: false))
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(wasMedia: false, willBeMedia: true, panelAlreadyBuilt: true, hasCustomTextView: false))
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(wasMedia: false, willBeMedia: true, panelAlreadyBuilt: false, hasCustomTextView: true), "poll option fields keep their own input")
    }

    func testAScheduledHandoffRunsOnce() {
        var gate = DeferredKeyboardHandoffGate()
        let token = gate.schedule()
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.consume(token))
        XCTAssertFalse(gate.consume(token), "the layout completion and the 0.4 s fallback must not both run it")
        XCTAssertFalse(gate.isPending)
    }

    func testANewerScheduleMakesTheOlderStale() {
        var gate = DeferredKeyboardHandoffGate()
        let first = gate.schedule()
        let second = gate.schedule()
        XCTAssertFalse(gate.consume(first))
        XCTAssertTrue(gate.consume(second))
    }

    func testCancelDropsAPendingHandoff() {
        var gate = DeferredKeyboardHandoffGate()
        let token = gate.schedule()
        gate.cancel()
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.consume(token), "the mode left media before the handoff ran")
        XCTAssertFalse(gate.consume(token))
    }

    func testCancelWithNothingPendingIsHarmless() {
        var gate = DeferredKeyboardHandoffGate()
        gate.cancel()
        let token = gate.schedule()
        XCTAssertTrue(gate.consume(token))
    }

    func testNothingIsCreatedBeforeThePaneIsOnScreen() {
        XCTAssertFalse(LazyGifTilePlan.mayCreateTile(paneSettled: false, createdInThisPass: 0))
    }

    func testTilesAreCreatedInBoundedPasses() {
        for created in 0 ..< LazyGifTilePlan.tilesPerPass {
            XCTAssertTrue(LazyGifTilePlan.mayCreateTile(paneSettled: true, createdInThisPass: created))
        }
        XCTAssertFalse(LazyGifTilePlan.mayCreateTile(paneSettled: true, createdInThisPass: LazyGifTilePlan.tilesPerPass))
        XCTAssertGreaterThan(LazyGifTilePlan.tilesPerPass, 0, "a pass that creates nothing would never finish")
    }

    func testSignpostNamesAreStableAndDistinct() {
        let names: [StaticString] = [
            EmojiPanelOpenSignpost.openToReady, EmojiPanelOpenSignpost.inputNodeForState, EmojiPanelOpenSignpost.inputNodeInit,
            EmojiPanelOpenSignpost.inputNodeUpdateLayout, EmojiPanelOpenSignpost.entityKeyboardUpdate, EmojiPanelOpenSignpost.gifLayerCreate,
            EmojiPanelOpenSignpost.reloadInputViews, EmojiPanelOpenSignpost.ensureFocused, EmojiPanelOpenSignpost.keyboardDismiss,
            EmojiPanelOpenSignpost.deferredKeyboardHandoff, EmojiPanelOpenSignpost.deferredGifTiles, EmojiPanelOpenSignpost.firstTurnAfterLayout
        ]
        let strings = names.map { "\($0)" }
        XCTAssertEqual(Set(strings).count, strings.count)
    }

    func testOpenIntervalCanBeBegunTwiceAndEndedWithoutABegin() {
        EmojiPanelOpenSignpost.endOpen()
        EmojiPanelOpenSignpost.beginOpen()
        EmojiPanelOpenSignpost.beginOpen()
        EmojiPanelOpenSignpost.endOpen()
    }
}

final class NextFrameTests: XCTestCase {
    func testTheBlockNeverRunsInlineAndRunsOnce() {
        var runs = 0
        let ran = expectation(description: "ran")
        NextFrame.run {
            runs += 1
            ran.fulfill()
        }
        XCTAssertEqual(runs, 0, "SwiftSignalKit's Queue.async would have run it inline here")
        wait(for: [ran], timeout: 2.0)
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
        XCTAssertEqual(runs, 1, "display link and fallback timer must not both run it")
    }

    func testCancelDropsTheBlock() {
        var runs = 0
        let task = NextFrame.run { runs += 1 }
        task.cancel()
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
        XCTAssertEqual(runs, 0)
    }

    func testADanglingOpenIntervalIsClosed() {
        EmojiPanelOpenSignpost.beginOpen()
        XCTAssertTrue(EmojiPanelOpenSignpost.isOpenIntervalActive)
        let closed = expectation(description: "closed")
        DispatchQueue.main.asyncAfter(deadline: .now() + EmojiPanelOpenSignpost.danglingOpenTimeout + 0.3) { closed.fulfill() }
        wait(for: [closed], timeout: EmojiPanelOpenSignpost.danglingOpenTimeout + 2.0)
        XCTAssertFalse(EmojiPanelOpenSignpost.isOpenIntervalActive)
    }
}
