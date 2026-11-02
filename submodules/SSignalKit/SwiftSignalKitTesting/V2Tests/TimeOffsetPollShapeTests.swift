import XCTest
import Foundation
import SwiftSignalKit2

final class TimeOffsetPollShapeTests: XCTestCase {
    func testAPollWhoseFirstSignalNeverCompletesReadsOnce() {
        let reads = Atomic<Int>(value: 0)
        let once = Signal<Double, NoError> { subscriber in
            let _ = reads.modify { $0 + 1 }
            subscriber.putNext(1.0)
            return EmptyDisposable
        }
        let poll = (once |> then(Signal<Double, NoError>.complete() |> delay(0.05, queue: Queue.concurrentDefaultQueue()))) |> restart |> map { round($0) } |> distinctUntilChanged
        let disposable = poll.start(next: { _ in })
        let waited = expectation(description: "waited")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            waited.fulfill()
        }
        wait(for: [waited], timeout: 5.0)
        disposable.dispose()
        XCTAssertEqual(reads.with { $0 }, 1)
    }

    func testADelayedSingleRestartRepeats() {
        let ticks = Atomic<Int>(value: 0)
        let poll = (Signal<Void, NoError>.single(Void()) |> delay(0.05, queue: Queue.concurrentDefaultQueue())) |> restart
        let disposable = poll.start(next: { _ in
            let _ = ticks.modify { $0 + 1 }
        })
        let waited = expectation(description: "waited")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            waited.fulfill()
        }
        wait(for: [waited], timeout: 5.0)
        disposable.dispose()
        XCTAssertGreaterThan(ticks.with { $0 }, 3)
    }
}
