import XCTest
@testable import ChatRowPrep

final class ChatRowPrefetchPlanGateTests: XCTestCase {
    private func signature() -> ChatRowPrefetchPlanGate.Signature {
        return ChatRowPrefetchPlanGate.Signature(first: 10, last: 40, direction: 1, width: 390.0, entriesRevision: 5, prefersSynchronousLoads: false)
    }

    func testFirstCallRuns() {
        var gate = ChatRowPrefetchPlanGate()
        XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 1.0))
    }

    func testUnchangedSignatureIsSkippedAndCounted() {
        var gate = ChatRowPrefetchPlanGate()
        XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 1.0))
        XCTAssertFalse(gate.shouldRun(signature: self.signature(), now: 1.016))
        XCTAssertFalse(gate.shouldRun(signature: self.signature(), now: 1.033))
        XCTAssertEqual(gate.skippedCount, 2)
    }

    func testEveryInputChangeRuns() {
        var variants: [ChatRowPrefetchPlanGate.Signature] = []
        var s = self.signature(); s.first = 11; variants.append(s)
        s = self.signature(); s.last = 41; variants.append(s)
        s = self.signature(); s.direction = -1; variants.append(s)
        s = self.signature(); s.width = 400.0; variants.append(s)
        s = self.signature(); s.entriesRevision = 6; variants.append(s)
        s = self.signature(); s.prefersSynchronousLoads = true; variants.append(s)
        for variant in variants {
            var gate = ChatRowPrefetchPlanGate()
            XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 1.0))
            XCTAssertTrue(gate.shouldRun(signature: variant, now: 1.016), "\(variant)")
        }
    }

    func testReplansAfterTheMaximumInterval() {
        var gate = ChatRowPrefetchPlanGate()
        XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 1.0))
        XCTAssertFalse(gate.shouldRun(signature: self.signature(), now: 1.2))
        XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 1.0 + ChatRowPrefetchPlanGate.maximumSkipInterval))
        // The interval restarts from the run that happened.
        XCTAssertFalse(gate.shouldRun(signature: self.signature(), now: 1.3))
    }

    func testClockGoingBackwardsRuns() {
        var gate = ChatRowPrefetchPlanGate()
        XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 5.0))
        XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 4.0))
    }

    func testResetForcesNextRun() {
        var gate = ChatRowPrefetchPlanGate()
        XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 1.0))
        gate.reset()
        XCTAssertTrue(gate.shouldRun(signature: self.signature(), now: 1.01))
    }
}
