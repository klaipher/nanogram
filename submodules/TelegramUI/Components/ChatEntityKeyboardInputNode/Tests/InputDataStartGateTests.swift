import XCTest
@testable import ChatEntityKeyboardInputNode

final class InputDataStartGateTests: XCTestCase {
    func testNothingStartsUntilATriggerArrives() {
        let gate = InputDataStartGate()
        XCTAssertFalse(gate.hasStarted)
    }

    func testDemandStartsOnce() {
        var gate = InputDataStartGate()
        XCTAssertTrue(gate.shouldStart(.demand))
        XCTAssertFalse(gate.shouldStart(.demand))
        XCTAssertFalse(gate.shouldStart(.idle), "the idle timer after a demand start must not build twice")
    }

    func testIdleStartsOnceAndALaterDemandDoesNotRestart() {
        var gate = InputDataStartGate()
        XCTAssertTrue(gate.shouldStart(.idle))
        XCTAssertFalse(gate.shouldStart(.demand))
    }

    func testIdleDelayIsAfterThePushTransitionButShort() {
        XCTAssertGreaterThanOrEqual(InputDataStartGate.idleDelay, 0.4, "after the ~0.35 s push transition")
        XCTAssertLessThanOrEqual(InputDataStartGate.idleDelay, 1.0, "an early panel open must not wait for a cold build")
    }

    func testIdleBuildWaitsWhileTheHistoryScrolls() {
        XCTAssertEqual(InputDataStartGate.idleDecision(secondsSinceLastScroll: nil), .startNow)
        XCTAssertEqual(InputDataStartGate.idleDecision(secondsSinceLastScroll: 5.0), .startNow)
        XCTAssertEqual(InputDataStartGate.idleDecision(secondsSinceLastScroll: 0.0), .retry(after: InputDataStartGate.scrollQuietPeriod))
        if case let .retry(after) = InputDataStartGate.idleDecision(secondsSinceLastScroll: 0.1) {
            XCTAssertEqual(after, InputDataStartGate.scrollQuietPeriod - 0.1, accuracy: 0.0001)
        } else {
            XCTFail("a scroll 0.1 s ago must postpone the build")
        }
    }

    func testPrewarmStartsOnceAndIdleOrDemandDoNotRestart() {
        var gate = InputDataStartGate()
        XCTAssertTrue(gate.shouldStart(.prewarm))
        XCTAssertFalse(gate.shouldStart(.prewarm), "a second touch-down or focus must not build twice")
        XCTAssertFalse(gate.shouldStart(.demand))
        XCTAssertFalse(gate.shouldStart(.idle))
    }

    func testFocusPrewarmWaitsForTheKeyboard() {
        XCTAssertGreaterThanOrEqual(InputDataStartGate.focusPrewarmWait, 0.35, "at least the keyboard animation")
    }

    func testAnExplicitDemandDuringTheFocusDelayStartsAtOnceAndTheDelayedStartIsANoOp() {
        var gate = InputDataStartGate()
        XCTAssertTrue(gate.shouldStart(.demand))
        XCTAssertFalse(gate.shouldStart(.idle), "the delayed focus start finds the data already started")
    }
}
