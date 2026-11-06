import XCTest
@testable import Display

final class SynchronousDecodeBudgetTests: XCTestCase {
    func testTheFirstLoadOfABurstIsAlwaysGranted() {
        let budget = SynchronousDecodeBudget(limit: 0.012, burstGap: 0.3)
        XCTAssertTrue(budget.allowsSynchronousLoad(now: 10.0))
    }

    func testAnExpensiveLoadSendsTheRestOfTheBurstOffMain() {
        let budget = SynchronousDecodeBudget(limit: 0.012, burstGap: 0.3)
        XCTAssertTrue(budget.allowsSynchronousLoad(now: 10.0))
        budget.recordSynchronousLoad(duration: 0.035, now: 10.04)
        XCTAssertFalse(budget.allowsSynchronousLoad(now: 10.05))
        XCTAssertFalse(budget.allowsSynchronousLoad(now: 10.2))
    }

    func testCheapLoadsKeepGoingUntilTheLimit() {
        let budget = SynchronousDecodeBudget(limit: 0.012, burstGap: 0.3)
        for index in 0 ..< 5 {
            let now = 10.0 + Double(index) * 0.003
            XCTAssertTrue(budget.allowsSynchronousLoad(now: now))
            budget.recordSynchronousLoad(duration: 0.002, now: now + 0.002)
        }
        XCTAssertTrue(budget.allowsSynchronousLoad(now: 10.02), "10 ms spent of 12 ms")
        budget.recordSynchronousLoad(duration: 0.003, now: 10.025)
        XCTAssertFalse(budget.allowsSynchronousLoad(now: 10.03))
    }

    func testAQuietGapStartsANewBurst() {
        let budget = SynchronousDecodeBudget(limit: 0.012, burstGap: 0.3)
        budget.recordSynchronousLoad(duration: 0.05, now: 10.0)
        XCTAssertFalse(budget.allowsSynchronousLoad(now: 10.1))
        XCTAssertTrue(budget.allowsSynchronousLoad(now: 10.4), "300 ms without a load ends the burst")
    }

    func testBackToBackBurstsStayOneBurst() {
        let budget = SynchronousDecodeBudget(limit: 0.012, burstGap: 0.3)
        budget.recordSynchronousLoad(duration: 0.02, now: 10.0)
        budget.recordSynchronousLoad(duration: 0.0, now: 10.25)
        XCTAssertFalse(budget.allowsSynchronousLoad(now: 10.5), "activity at 10.25 keeps the burst open")
    }

    func testNegativeDurationsAreIgnored() {
        let budget = SynchronousDecodeBudget(limit: 0.012, burstGap: 0.3)
        budget.recordSynchronousLoad(duration: -1.0, now: 10.0)
        XCTAssertTrue(budget.allowsSynchronousLoad(now: 10.01))
    }
}
