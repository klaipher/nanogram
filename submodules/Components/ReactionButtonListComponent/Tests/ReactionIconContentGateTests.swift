import Foundation
import XCTest
@testable import ReactionButtonListComponent

// A reaction sent from the picker lands in the message's reaction button as the picker's own node,
// which stands in for the button's animation layer until it is handed off. The button's layer
// loads its first frame asynchronously, and with a cold animation cache (every icon after a cache
// format bump) it had not drawn one by then: the stand-in was removed and the button showed nothing
// for a few seconds. The hand-off now waits for the layer's first frame. There is no timeout: a
// timeout could only reveal an empty layer, and the stand-in's lifetime is bounded by the button
// (a reset removes it, a reaction switch hands off at once).
final class ReactionIconContentGateTests: XCTestCase {
    func testHandOffWaitsForFirstFrame() {
        let gate = ReactionIconContentGate()
        var handedOff = 0
        gate.whenContentReady({
            handedOff += 1
        })
        XCTAssertEqual(handedOff, 0, "the stand-in must stay while the layer has no frame")

        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1, "the first frame hands off at once")

        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1, "a hand-off runs once")
    }

    func testHandOffIsImmediateWhenTheLayerAlreadyHasAFrame() {
        let gate = ReactionIconContentGate()
        gate.setHasContent(true)
        var handedOff = 0
        gate.whenContentReady({
            handedOff += 1
        })
        XCTAssertEqual(handedOff, 1)
    }

    // The old 3 s fallback revealed a layer that still had nothing to show. Waiting is now bounded
    // only by the button: nothing hands off before the first frame, however long it takes.
    func testNoTimeoutRevealsAnEmptyLayer() {
        let gate = ReactionIconContentGate()
        var handedOff = 0
        gate.whenContentReady({
            handedOff += 1
        })
        let waited = expectation(description: "past the old timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: {
            waited.fulfill()
        })
        wait(for: [waited], timeout: 5.0)
        XCTAssertEqual(handedOff, 0, "no hand-off without a frame")
        XCTAssertTrue(gate.hasPendingWork)

        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1)
        XCTAssertFalse(gate.hasPendingWork)
    }

    func testANewLayerWaitsAgain() {
        let gate = ReactionIconContentGate()
        gate.setHasContent(true)
        // The button replaced its layer (a new file, a pause): the new one has drawn nothing yet.
        gate.setHasContent(false)
        var handedOff = 0
        gate.whenContentReady({
            handedOff += 1
        })
        XCTAssertEqual(handedOff, 0)
        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1)
    }

    func testAnotherReactionHandsOffAtOnce() {
        let gate = ReactionIconContentGate()
        var handedOff = 0
        gate.whenContentReady({
            handedOff += 1
        })
        // The button now shows another reaction: the stand-in is for the old one and goes at once.
        gate.runPending()
        XCTAssertEqual(handedOff, 1)
        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1)
    }

    func testCancelDropsPendingHandOffs() {
        let gate = ReactionIconContentGate()
        var handedOff = 0
        gate.whenContentReady({
            handedOff += 1
        })
        // The button was reused for another reaction: its subviews, the stand-in included, are gone.
        gate.cancelAll()
        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 0)
        XCTAssertFalse(gate.hasPendingWork)
    }
}
