import Foundation
import XCTest
import SwiftSignalKit
@testable import MediaAssetsContext

final class ThumbnailScrollGateTests: XCTestCase {
    private final class Clock {
        var time: Double = 0.0
    }

    private final class Harness {
        let clock = Clock()
        var offset: Double = 0.0
        let gate: ThumbnailScrollGate

        init() {
            let clock = self.clock
            var storedTick: (() -> Void)?
            self.gate = ThumbnailScrollGate(now: { clock.time }, makeTimer: { completion in
                storedTick = completion
                // Never started in a test; `fireTimer` calls the completion by hand.
                return Timer(timeout: 3600.0, repeat: false, completion: { () -> Void in }, queue: Queue.mainQueue())
            })
            self.tickProvider = { storedTick }
        }

        private var tickProvider: (() -> (() -> Void)?)?

        func fireTimer() {
            self.tickProvider?()?()
        }

        func scroll(speed: Double, ticks: Int) {
            for _ in 0 ..< ticks {
                self.clock.time += 1.0 / 60.0
                self.offset += speed / 60.0
                self.gate.noteOffset(self.offset)
            }
        }
    }

    func testCalmGridStartsRequestsSynchronously() {
        let harness = Harness()
        var started = 0
        let disposable = harness.gate.whenCalm().start(next: { _ in started += 1 })
        XCTAssertEqual(started, 1)
        disposable.dispose()
    }

    func testFlingHoldsRequestsUntilTheGridSlows() {
        let harness = Harness()
        harness.scroll(speed: 4000.0, ticks: 20)
        XCTAssertTrue(harness.gate.isFlinging)
        var started = 0
        let disposable = harness.gate.whenCalm().start(next: { _ in started += 1 })
        XCTAssertEqual(started, 0)
        harness.scroll(speed: 4000.0, ticks: 5)
        XCTAssertEqual(started, 0)
        harness.scroll(speed: 300.0, ticks: 10)
        XCTAssertEqual(started, 1)
        disposable.dispose()
    }

    func testTheTimerReleasesWaitersWhenOffsetsStop() {
        let harness = Harness()
        harness.scroll(speed: 4000.0, ticks: 20)
        var started = 0
        let disposable = harness.gate.whenCalm().start(next: { _ in started += 1 })
        XCTAssertEqual(started, 0)
        harness.clock.time += 0.5
        harness.fireTimer()
        XCTAssertEqual(started, 1)
        disposable.dispose()
    }

    func testDisposedWaitersAreNeverStarted() {
        let harness = Harness()
        harness.scroll(speed: 4000.0, ticks: 20)
        var started = 0
        let disposable = harness.gate.whenCalm().start(next: { _ in started += 1 })
        disposable.dispose()
        // Disposal removes the waiter on the main queue.
        let expectation = self.expectation(description: "main queue turn")
        Queue.mainQueue().async {
            expectation.fulfill()
        }
        self.wait(for: [expectation], timeout: 2.0)
        harness.scroll(speed: 100.0, ticks: 10)
        XCTAssertEqual(started, 0)
    }
}
