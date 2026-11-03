import Foundation
import XCTest
@testable import ReactionButtonListComponent

// A reaction sent from the picker lands in the message's reaction button as the picker's own node,
// which stands in for the button's animation layer until the picker's 2 s timer. The button's layer
// loads its first frame asynchronously, and with a cold animation cache (every icon after a cache
// format bump) it had not drawn one by then: the stand-in was removed and the button showed nothing
// for a few seconds. The hand-off now waits for the layer's first frame, at most a bounded time.
final class ReactionIconContentGateTests: XCTestCase {
    private final class ManualScheduler {
        var scheduled: [(delay: Double, action: () -> Void)] = []

        func schedule(_ delay: Double, _ action: @escaping () -> Void) {
            self.scheduled.append((delay, action))
        }

        func fireAll() {
            let items = self.scheduled
            self.scheduled.removeAll()
            for item in items {
                item.action()
            }
        }
    }

    func testHandOffWaitsForFirstFrame() {
        let scheduler = ManualScheduler()
        let gate = ReactionIconContentGate(schedule: scheduler.schedule)
        var handedOff = 0
        gate.whenContentReady(timeout: 3.0, {
            handedOff += 1
        })
        XCTAssertEqual(handedOff, 0, "the stand-in must stay while the layer has no frame")

        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1, "the first frame hands off at once")

        scheduler.fireAll()
        XCTAssertEqual(handedOff, 1, "the timeout does not hand off a second time")
    }

    func testHandOffIsImmediateWhenTheLayerAlreadyHasAFrame() {
        let scheduler = ManualScheduler()
        let gate = ReactionIconContentGate(schedule: scheduler.schedule)
        gate.setHasContent(true)
        var handedOff = 0
        gate.whenContentReady(timeout: 3.0, {
            handedOff += 1
        })
        XCTAssertEqual(handedOff, 1)
        XCTAssertTrue(scheduler.scheduled.isEmpty, "no timer when nothing waits")
    }

    func testHandOffFallsBackAfterTheTimeout() {
        let scheduler = ManualScheduler()
        let gate = ReactionIconContentGate(schedule: scheduler.schedule)
        var handedOff = 0
        gate.whenContentReady(timeout: 3.0, {
            handedOff += 1
        })
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [3.0])
        scheduler.fireAll()
        XCTAssertEqual(handedOff, 1, "a layer that never draws is revealed after the timeout")

        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1, "a late frame does not hand off a second time")
    }

    func testANewLayerWaitsAgain() {
        let scheduler = ManualScheduler()
        let gate = ReactionIconContentGate(schedule: scheduler.schedule)
        gate.setHasContent(true)
        // The button replaced its layer (a new file, a pause): the new one has drawn nothing yet.
        gate.setHasContent(false)
        var handedOff = 0
        gate.whenContentReady(timeout: 3.0, {
            handedOff += 1
        })
        XCTAssertEqual(handedOff, 0)
        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1)
    }

    func testAnotherReactionHandsOffAtOnce() {
        let scheduler = ManualScheduler()
        let gate = ReactionIconContentGate(schedule: scheduler.schedule)
        var handedOff = 0
        gate.whenContentReady(timeout: 3.0, {
            handedOff += 1
        })
        // The button now shows another reaction: the stand-in is for the old one and goes at once.
        gate.runPending()
        XCTAssertEqual(handedOff, 1)
        scheduler.fireAll()
        gate.setHasContent(true)
        XCTAssertEqual(handedOff, 1)
    }

    func testCancelDropsPendingHandOffs() {
        let scheduler = ManualScheduler()
        let gate = ReactionIconContentGate(schedule: scheduler.schedule)
        var handedOff = 0
        gate.whenContentReady(timeout: 3.0, {
            handedOff += 1
        })
        // The button was reused for another reaction: its subviews, the stand-in included, are gone.
        gate.cancelAll()
        gate.setHasContent(true)
        scheduler.fireAll()
        XCTAssertEqual(handedOff, 0)
    }
}
