import XCTest
@testable import CoreListDemo

final class RebalanceRowBudgetTests: XCTestCase {
    func testRowsThatFillAVisibleGapAreAlwaysAdmitted() {
        var budget = RebalanceRowBudget(maxSpeculativeRows: 1)
        for _ in 0..<10 {
            XCTAssertTrue(budget.admit(edgeIsInsideViewport: true))
        }
        XCTAssertEqual(budget.speculativeRows, 0)
        XCTAssertFalse(budget.deferred)
    }

    func testSpeculativeRowsStopAtTheCapAndReportDeferral() {
        var budget = RebalanceRowBudget(maxSpeculativeRows: 1)
        XCTAssertTrue(budget.admit(edgeIsInsideViewport: false))
        XCTAssertFalse(budget.deferred)
        XCTAssertFalse(budget.admit(edgeIsInsideViewport: false))
        XCTAssertTrue(budget.deferred)
        XCTAssertEqual(budget.speculativeRows, 1)
    }

    func testVisibleGapStillAdmittedAfterTheCapIsSpent() {
        var budget = RebalanceRowBudget(maxSpeculativeRows: 1)
        XCTAssertTrue(budget.admit(edgeIsInsideViewport: false))
        XCTAssertFalse(budget.admit(edgeIsInsideViewport: false))
        XCTAssertTrue(budget.admit(edgeIsInsideViewport: true))
    }

    func testDefaultCapIsUnlimited() {
        var budget = RebalanceRowBudget(maxSpeculativeRows: .max)
        for _ in 0..<1000 {
            XCTAssertTrue(budget.admit(edgeIsInsideViewport: false))
        }
        XCTAssertFalse(budget.deferred)
    }

    func testTickSignatureDiffersOnAnyInput() {
        let base = ScrollTickSignature(offset: 10, solveOffset: 10, windowRevision: 1, containerOriginY: 0,
                                       logicalSize: CGSize(width: 390, height: 800), insets: .zero)
        XCTAssertEqual(base, base)
        var changed = base
        changed.offset = 11
        XCTAssertNotEqual(base, changed)
        changed = base
        changed.windowRevision = 2
        XCTAssertNotEqual(base, changed)
        changed = base
        changed.insets = UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
        XCTAssertNotEqual(base, changed)
    }
}

final class ScrollActivityDebounceTests: XCTestCase {
    func testFirstNoteArmsAndLaterNotesDoNot() {
        var debounce = ScrollActivityDebounce(timeout: 0.3)
        XCTAssertTrue(debounce.note(at: 1.0))
        XCTAssertFalse(debounce.note(at: 1.1))
        XCTAssertFalse(debounce.note(at: 1.2))
    }

    func testTimerFiringEarlyRearmsForTheRemainder() {
        var debounce = ScrollActivityDebounce(timeout: 0.3)
        _ = debounce.note(at: 1.0)
        _ = debounce.note(at: 1.2)
        let remaining = debounce.expire(at: 1.3)
        XCTAssertNotNil(remaining)
        XCTAssertEqual(remaining ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertNil(debounce.expire(at: 1.5))
    }

    func testExpiryClearsSoTheNextNoteArmsAgain() {
        var debounce = ScrollActivityDebounce(timeout: 0.3)
        _ = debounce.note(at: 1.0)
        XCTAssertNil(debounce.expire(at: 1.31))
        XCTAssertNil(debounce.lastActivity)
        XCTAssertTrue(debounce.note(at: 2.0))
    }
}
