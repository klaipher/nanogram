import XCTest
import Foundation
#if SSK_LEGACY
@testable import SwiftSignalKitLegacy
#else
@testable import SwiftSignalKit2
#endif

final class OperatorCoalesceOnMainTests: XCTestCase {
    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                drained.fulfill()
            }
        }
        wait(for: [drained], timeout: 5.0)
    }

    func testValuesOfOneTurnAreMergedToTheLastOne() {
        let log = OperatorLog()
        let a = OperatorSource<Int, String>("a", log)
        let values = OperatorBox<Int>()
        let disposable = (a.signal |> coalesceOnMain).start(next: { value in
            values.append(value)
        })
        for value in 0 ..< 100 {
            a.emit(value)
        }
        XCTAssertEqual(values.values, [], "nothing is delivered before the main queue runs")
        self.drainMain()
        XCTAssertEqual(values.values, [99])
        disposable.dispose()
    }

    func testValuesOfLaterTurnsAreEachDelivered() {
        let log = OperatorLog()
        let a = OperatorSource<Int, String>("a", log)
        let values = OperatorBox<Int>()
        let disposable = (a.signal |> coalesceOnMain).start(next: { value in
            values.append(value)
        })
        a.emit(1)
        a.emit(2)
        self.drainMain()
        a.emit(3)
        self.drainMain()
        XCTAssertEqual(values.values, [2, 3])
        disposable.dispose()
    }

    func testDeliversOnTheMainQueue() {
        let a = OperatorSource<Int, String>("a", OperatorLog())
        let onMain = OperatorBox<Bool>()
        let disposable = (a.signal |> coalesceOnMain).start(next: { _ in
            onMain.append(Thread.isMainThread)
        })
        let queue = DispatchQueue(label: "operator.coalesce.producer")
        let produced = expectation(description: "produced")
        queue.async {
            a.emit(1)
            produced.fulfill()
        }
        wait(for: [produced], timeout: 5.0)
        self.drainMain()
        XCTAssertEqual(onMain.values, [true])
        disposable.dispose()
    }

    func testOnlyOneMainDispatchIsMadeForAWholeBurst() {
        let a = OperatorSource<Int, String>("a", OperatorLog())
        let deliveries = OperatorBox<Int>()
        let disposable = (a.signal |> coalesceOnMain).start(next: { value in
            deliveries.append(value)
        })
        var marks: [Int] = []
        let marker = expectation(description: "marker")
        for value in 0 ..< 1000 {
            a.emit(value)
        }
        // Queued behind the (single) flush: everything the flush delivered is visible by the time this runs.
        DispatchQueue.main.async {
            marks = deliveries.values
            marker.fulfill()
        }
        wait(for: [marker], timeout: 5.0)
        XCTAssertEqual(marks, [999])
        disposable.dispose()
    }

    func testCompletionFlushesThePendingValueFirst() {
        let log = OperatorLog()
        let a = OperatorSource<Int, String>("a", log)
        let events = OperatorBox<String>()
        let done = expectation(description: "completed")
        let disposable = (a.signal |> coalesceOnMain).start(next: { value in
            events.append("next \(value)")
        }, completed: {
            events.append("completed")
            done.fulfill()
        })
        a.emit(1)
        a.emit(2)
        a.complete()
        wait(for: [done], timeout: 5.0)
        XCTAssertEqual(events.values, ["next 2", "completed"])
        disposable.dispose()
    }

    func testAnErrorFlushesThePendingValueFirst() {
        let a = OperatorSource<Int, String>("a", OperatorLog())
        let events = OperatorBox<String>()
        let done = expectation(description: "failed")
        let disposable = (a.signal |> coalesceOnMain).start(next: { value in
            events.append("next \(value)")
        }, error: { error in
            events.append("error \(error)")
            done.fulfill()
        })
        a.emit(7)
        a.fail("boom")
        wait(for: [done], timeout: 5.0)
        XCTAssertEqual(events.values, ["next 7", "error boom"])
        disposable.dispose()
    }

    func testCompletionWithoutAValueIsDelivered() {
        let a = OperatorSource<Int, String>("a", OperatorLog())
        let done = expectation(description: "completed")
        let disposable = (a.signal |> coalesceOnMain).start(completed: {
            done.fulfill()
        })
        a.complete()
        wait(for: [done], timeout: 5.0)
        disposable.dispose()
    }

    func testDisposingDropsThePendingValueAndDisposesUpstream() {
        let log = OperatorLog()
        let a = OperatorSource<Int, String>("a", log)
        let values = OperatorBox<Int>()
        let disposable = (a.signal |> coalesceOnMain).start(next: { value in
            values.append(value)
        })
        a.emit(1)
        disposable.dispose()
        self.drainMain()
        XCTAssertEqual(values.values, [])
        XCTAssertEqual(log.count(of: "a.dispose#1"), 1)
    }

    func testNothingIsDeliveredAfterCompletion() {
        let a = OperatorSource<Int, String>("a", OperatorLog())
        let events = OperatorBox<String>()
        let done = expectation(description: "completed")
        let disposable = (a.signal |> coalesceOnMain).start(next: { value in
            events.append("next \(value)")
        }, completed: {
            events.append("completed")
            done.fulfill()
        })
        a.emit(1)
        a.complete()
        a.emit(2)
        wait(for: [done], timeout: 5.0)
        self.drainMain()
        XCTAssertEqual(events.values, ["next 1", "completed"])
        disposable.dispose()
    }
}
