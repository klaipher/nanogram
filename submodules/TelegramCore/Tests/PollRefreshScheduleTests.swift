import XCTest
import SwiftSignalKit
@testable import TelegramCore

final class PollRefreshScheduleTests: XCTestCase {
    func testTheWaitIsTheTimeLeftUntilTheDeadline() {
        XCTAssertEqual(pollRefreshRemainingTime(startDate: 1000, deadlineTimeout: 600, deadlineDate: nil, now: 1100), 500)
        XCTAssertEqual(pollRefreshRemainingTime(startDate: 1000, deadlineTimeout: 600, deadlineDate: 1300, now: 1100), 200)
        XCTAssertEqual(pollRefreshRemainingTime(startDate: 1000, deadlineTimeout: 60, deadlineDate: nil, now: 2000), -940)
        XCTAssertNil(pollRefreshRemainingTime(startDate: 1000, deadlineTimeout: nil, deadlineDate: nil, now: 1100))
    }

    private func countFetches(reachedDeadline: Bool, duration: Double) -> Int {
        let fetches = Atomic<Int>(value: 0)
        let fetch = Signal<Never, NoError> { subscriber in
            let _ = fetches.modify { $0 + 1 }
            subscriber.putCompletion()
            return EmptyDisposable
        }
        let disposable = pollRefreshSignal(fetch: fetch, reachedDeadline: reachedDeadline, burstInterval: 0.01, regularInterval: 60.0).start()
        Thread.sleep(forTimeInterval: duration)
        disposable.dispose()
        return fetches.with { $0 }
    }

    func testAfterTheDeadlineAShortBurstFallsBackToTheRegularRefresh() {
        XCTAssertEqual(self.countFetches(reachedDeadline: true, duration: 1.0), 11)
    }

    func testBeforeTheDeadlineTheRegularRefreshRuns() {
        XCTAssertEqual(self.countFetches(reachedDeadline: false, duration: 0.3), 1)
    }
}
