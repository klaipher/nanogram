import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// The walker schedule waits for the day to pass instead of giving up at launch.
final class CacheWalkerScheduleTests: XCTestCase {
    private func runCount(record: CacheWalkerRecord?, fingerprint: String, wait: Double) -> (runs: Int, skipped: Int) {
        let runs = Atomic<Int>(value: 0)
        let skipped = Atomic<Int>(value: 0)
        let run = Signal<Never, NoError> { subscriber in
            let _ = runs.modify { $0 + 1 }
            subscriber.putCompletion()
            return EmptyDisposable
        }
        let disposable = CacheWalkerSchedule.signal(
            recordSignal: .single(record),
            fingerprint: fingerprint,
            configuredDelay: 0.0,
            processStartTime: 0.0,
            queue: Queue.concurrentDefaultQueue(),
            skipped: { _ in
                let _ = skipped.modify { $0 + 1 }
            },
            run: run
        ).start()
        Thread.sleep(forTimeInterval: wait)
        disposable.dispose()
        return (runs.with { $0 }, skipped.with { $0 })
    }

    func testADueWalkerRunsOnceAndWaitsBeforeTheNextRun() {
        let result = self.runCount(record: nil, fingerprint: "a", wait: 0.5)
        XCTAssertEqual(result.runs, 1)
        XCTAssertEqual(result.skipped, 0)
    }

    func testAWalkerThatIsNotDueIsReportedAndDoesNotRunNow() {
        let record = CacheWalkerRecord(completedAt: Date().timeIntervalSince1970 - 3600.0, fingerprint: "a")
        let result = self.runCount(record: record, fingerprint: "a", wait: 0.5)
        XCTAssertEqual(result.runs, 0)
        XCTAssertEqual(result.skipped, 1)
    }

    func testChangedLimitsRunAtOnce() {
        let record = CacheWalkerRecord(completedAt: Date().timeIntervalSince1970 - 60.0, fingerprint: "a")
        let result = self.runCount(record: record, fingerprint: "b", wait: 0.5)
        XCTAssertEqual(result.runs, 1)
    }

    func testTheRearmedRunIsNeverSoonerThanTheFloor() {
        XCTAssertGreaterThanOrEqual(CacheWalkerSchedule.minimumRearmDelay, 3600.0)
    }
}
