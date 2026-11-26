import XCTest
@testable import Display

final class DiagnosticShortLogBudgetTests: XCTestCase {
    func testOneLinePerIntervalPerKey() {
        var budget = DiagnosticShortLogBudget(interval: 60.0, maxLinesPerWindow: 100, window: 3600.0)
        XCTAssertTrue(budget.allow(key: "a", now: 1000.0))
        XCTAssertFalse(budget.allow(key: "a", now: 1030.0))
        XCTAssertTrue(budget.allow(key: "b", now: 1030.0))
        XCTAssertTrue(budget.allow(key: "a", now: 1060.0))
    }

    func testAtMostMaxLinesPerWindowAcrossKeys() {
        var budget = DiagnosticShortLogBudget(interval: 0.0, maxLinesPerWindow: 3, window: 3600.0)
        XCTAssertTrue(budget.allow(key: "a", now: 0.0))
        XCTAssertTrue(budget.allow(key: "b", now: 1.0))
        XCTAssertTrue(budget.allow(key: "a", now: 2.0))
        XCTAssertFalse(budget.allow(key: "c", now: 3.0))
        XCTAssertFalse(budget.allow(key: "a", now: 3599.0))
        // A new window starts once the old one has passed.
        XCTAssertTrue(budget.allow(key: "c", now: 3600.0))
    }

    func testARefusedLineDoesNotUseTheKeysInterval() {
        var budget = DiagnosticShortLogBudget(interval: 60.0, maxLinesPerWindow: 1, window: 100.0)
        XCTAssertTrue(budget.allow(key: "a", now: 0.0))
        XCTAssertFalse(budget.allow(key: "b", now: 10.0))
        // "b" was refused by the window cap, so it is not held back by its own interval in the next window.
        XCTAssertTrue(budget.allow(key: "b", now: 100.0))
    }

    func testAClockThatWentBackwardsDoesNotSilenceTheLog() {
        var budget = DiagnosticShortLogBudget(interval: 60.0, maxLinesPerWindow: 1, window: 3600.0)
        XCTAssertTrue(budget.allow(key: "a", now: 5000.0))
        XCTAssertFalse(budget.allow(key: "a", now: 5001.0))
        XCTAssertTrue(budget.allow(key: "a", now: 10.0))
    }

    func testTrimmedKeepsShortLinesAndCutsLongOnesToTheByteLimit() {
        XCTAssertEqual(DiagnosticShortLogBudget.trimmed("short", maxBytes: 16), "short")
        XCTAssertEqual(DiagnosticShortLogBudget.trimmed("0123456789abcdef", maxBytes: 16), "0123456789abcdef")
        let cut = DiagnosticShortLogBudget.trimmed("0123456789abcdefg", maxBytes: 16)
        XCTAssertEqual(cut, "0123456789abc...")
        XCTAssertEqual(cut.utf8.count, 16)
    }

    func testTrimmedNeverSplitsACharacter() {
        let line = String(repeating: "\u{00e9}", count: 20)
        let cut = DiagnosticShortLogBudget.trimmed(line, maxBytes: 10)
        XCTAssertLessThanOrEqual(cut.utf8.count, 10)
        XCTAssertEqual(cut, String(repeating: "\u{00e9}", count: 3) + "...")
    }

    func testGateAppliesTheBudget() {
        let gate = DiagnosticShortLogGate(interval: 60.0, maxLinesPerWindow: 10, window: 3600.0)
        XCTAssertTrue(gate.allow(key: "a", now: 0.0))
        XCTAssertFalse(gate.allow(key: "a", now: 1.0))
        XCTAssertTrue(gate.allow(key: "b", now: 1.0))
    }
}
