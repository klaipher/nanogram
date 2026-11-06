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

    func testIdleDelayLeavesChatOpenWindowFree() {
        XCTAssertGreaterThanOrEqual(InputDataStartGate.idleDelay, 2.0)
    }

    func testPrewarmStartsOnceAndIdleOrDemandDoNotRestart() {
        var gate = InputDataStartGate()
        XCTAssertTrue(gate.shouldStart(.prewarm))
        XCTAssertFalse(gate.shouldStart(.prewarm), "a second touch-down or focus must not build twice")
        XCTAssertFalse(gate.shouldStart(.demand))
        XCTAssertFalse(gate.shouldStart(.idle))
    }
}
