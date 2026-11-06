import Foundation
import XCTest
@testable import EntityKeyboard

final class EmojiPanelOpenTuningTests: XCTestCase {
    override func tearDown() {
        EmojiPanelOpenTuning.setDefersHeavyWork(false)
        super.tearDown()
    }

    func testTheSwitchIsOffByDefaultAndCached() {
        XCTAssertFalse(EmojiPanelOpenTuning.defersHeavyWork)
        EmojiPanelOpenTuning.setDefersHeavyWork(true)
        XCTAssertTrue(EmojiPanelOpenTuning.defersHeavyWork)
        EmojiPanelOpenTuning.setDefersHeavyWork(false)
        XCTAssertFalse(EmojiPanelOpenTuning.defersHeavyWork)
    }

    func testHandoffIsDeferredOnlyWhenSwitchingIntoMediaWithoutAPanel() {
        XCTAssertTrue(DeferredKeyboardHandoffGate.shouldDefer(switchEnabled: true, wasMedia: false, willBeMedia: true, panelAlreadyBuilt: false, hasCustomTextView: false))
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(switchEnabled: false, wasMedia: false, willBeMedia: true, panelAlreadyBuilt: false, hasCustomTextView: false), "switch off = today's path")
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(switchEnabled: true, wasMedia: true, willBeMedia: true, panelAlreadyBuilt: false, hasCustomTextView: false))
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(switchEnabled: true, wasMedia: false, willBeMedia: false, panelAlreadyBuilt: false, hasCustomTextView: false))
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(switchEnabled: true, wasMedia: false, willBeMedia: true, panelAlreadyBuilt: true, hasCustomTextView: false))
        XCTAssertFalse(DeferredKeyboardHandoffGate.shouldDefer(switchEnabled: true, wasMedia: false, willBeMedia: true, panelAlreadyBuilt: false, hasCustomTextView: true), "poll option fields keep their own input")
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

    func testWithTheSwitchOffEveryTileIsCreatedAtOnce() {
        XCTAssertTrue(LazyGifTilePlan.mayCreateTile(switchEnabled: false, paneSettled: false, createdInThisPass: 0))
        XCTAssertTrue(LazyGifTilePlan.mayCreateTile(switchEnabled: false, paneSettled: false, createdInThisPass: 10_000))
    }

    func testWithTheSwitchOnNothingIsCreatedBeforeThePaneIsOnScreen() {
        XCTAssertFalse(LazyGifTilePlan.mayCreateTile(switchEnabled: true, paneSettled: false, createdInThisPass: 0))
    }

    func testWithTheSwitchOnTilesAreCreatedInBoundedPasses() {
        for created in 0 ..< LazyGifTilePlan.tilesPerPass {
            XCTAssertTrue(LazyGifTilePlan.mayCreateTile(switchEnabled: true, paneSettled: true, createdInThisPass: created))
        }
        XCTAssertFalse(LazyGifTilePlan.mayCreateTile(switchEnabled: true, paneSettled: true, createdInThisPass: LazyGifTilePlan.tilesPerPass))
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
