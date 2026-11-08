import XCTest
import SwiftSignalKit
@testable import TelegramCore

final class RequestCoalescerStateTests: XCTestCase {
    private typealias State = RequestCoalescerState<String, Int>

    private func startFlight(_ join: State.Join, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard case let .start(flight) = join else {
            XCTFail("expected a new request, got \(join)", file: file, line: line)
            return -1
        }
        return flight
    }

    // (i) duplicate concurrent requests collapse
    func testConcurrentDuplicatesShareOneRequest() {
        var state = State(lifetime: 60)
        let flight = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        guard case let .joined(second) = state.join(key: "a", waiter: 2, now: 0.001),
              case let .joined(third) = state.join(key: "a", waiter: 3, now: 0.002) else {
            return XCTFail("the second and third caller must join the running request")
        }
        XCTAssertEqual(second, flight)
        XCTAssertEqual(third, flight)
        XCTAssertEqual(state.complete(flight: flight, value: 5, retryAfter: 0, now: 1), [1, 2, 3])
    }

    func testDifferentKeysAreIndependent() {
        var state = State(lifetime: 60)
        let a = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        let b = self.startFlight(state.join(key: "b", waiter: 2, now: 0))
        XCTAssertNotEqual(a, b)
    }

    // (iii) time-based expiry
    func testResultIsUsedUntilItExpires() {
        var state = State(lifetime: 60)
        let flight = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        _ = state.complete(flight: flight, value: 5, retryAfter: 0, now: 1)
        guard case .cached(5) = state.join(key: "a", waiter: 2, now: 60.9) else {
            return XCTFail("a result younger than the lifetime must be used")
        }
        guard case .start = state.join(key: "a", waiter: 3, now: 61.0) else {
            return XCTFail("a result of the lifetime's age must be asked for again")
        }
    }

    func testExpiredResultsArePrunedWhenANewOneIsStored() {
        var state = State(lifetime: 10)
        for i in 0 ..< 50 {
            let flight = self.startFlight(state.join(key: "k\(i)", waiter: i, now: Double(i) * 20))
            _ = state.complete(flight: flight, value: i, retryAfter: 0, now: Double(i) * 20)
        }
        XCTAssertEqual(state.storedCount, 1)
    }

    // (ii) the cache is bypassed after invalidation
    func testInvalidateDropsTheResult() {
        var state = State(lifetime: 60)
        let flight = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        _ = state.complete(flight: flight, value: 5, retryAfter: 0, now: 1)
        state.invalidate(key: "a")
        guard case .start = state.join(key: "a", waiter: 2, now: 2) else {
            return XCTFail("an invalidated key must be asked for again")
        }
    }

    func testInvalidateAllDropsEveryResult() {
        var state = State(lifetime: 60)
        for key in ["a", "b"] {
            let flight = self.startFlight(state.join(key: key, waiter: 1, now: 0))
            _ = state.complete(flight: flight, value: 5, retryAfter: 0, now: 1)
        }
        state.invalidateAll()
        guard case .start = state.join(key: "a", waiter: 2, now: 2), case .start = state.join(key: "b", waiter: 3, now: 2) else {
            return XCTFail("every key must be asked for again")
        }
    }

    func testInvalidationDuringARequestKeepsItsAnswerOutOfTheCacheAndOffNewCallers() {
        var state = State(lifetime: 60)
        let old = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        state.invalidate(key: "a")
        let new = self.startFlight(state.join(key: "a", waiter: 2, now: 0.5))
        XCTAssertNotEqual(old, new, "a caller after the change must not wait for the request from before it")
        XCTAssertEqual(state.complete(flight: old, value: 1, retryAfter: 0, now: 1), [1])
        guard case .joined(new) = state.join(key: "a", waiter: 3, now: 1) else {
            return XCTFail("the new request is still the one running")
        }
        XCTAssertEqual(state.complete(flight: new, value: 2, retryAfter: 0, now: 2), [2, 3])
        guard case .cached(2) = state.join(key: "a", waiter: 4, now: 3) else {
            return XCTFail("only the answer sent after the change is remembered")
        }
    }

    // a failure is never remembered; a FLOOD_WAIT is respected
    func testFailureIsNotRemembered() {
        var state = State(lifetime: 60)
        let flight = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        XCTAssertEqual(state.complete(flight: flight, value: nil, retryAfter: 0, now: 1), [1])
        guard case .start = state.join(key: "a", waiter: 2, now: 1) else {
            return XCTFail("a failure without a requested pause is retried at once, as before")
        }
    }

    func testFloodWaitIsRespectedAndThenExpires() {
        var state = State(lifetime: 60)
        let flight = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        _ = state.complete(flight: flight, value: nil, retryAfter: 35, now: 1)
        guard case .backedOff = state.join(key: "a", waiter: 2, now: 35.9) else {
            return XCTFail("no request before the pause the server asked for has elapsed")
        }
        guard case .start = state.join(key: "a", waiter: 3, now: 36.0) else {
            return XCTFail("the request is sent again once the pause has elapsed")
        }
    }

    func testInvalidationEndsABackoff() {
        var state = State(lifetime: 60)
        let flight = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        _ = state.complete(flight: flight, value: nil, retryAfter: 35, now: 1)
        state.invalidate(key: "a")
        guard case .start = state.join(key: "a", waiter: 2, now: 2) else {
            return XCTFail("a user action must not be held back by an earlier pause")
        }
    }

    func testLeavingTheLastWaiterCancelsTheRequest() {
        var state = State(lifetime: 60)
        let flight = self.startFlight(state.join(key: "a", waiter: 1, now: 0))
        guard case .joined = state.join(key: "a", waiter: 2, now: 0) else {
            return XCTFail("must join")
        }
        XCTAssertFalse(state.leave(flight: flight, waiter: 1))
        XCTAssertTrue(state.leave(flight: flight, waiter: 2))
        XCTAssertEqual(state.flightCount, 0)
        guard case .start = state.join(key: "a", waiter: 3, now: 0) else {
            return XCTFail("a cancelled request is started again")
        }
    }

    func testRetryAfterIsParsedFromFloodWaitTexts() {
        XCTAssertEqual(requestCoalescerRetryAfter(errorDescription: "FLOOD_WAIT_35"), 35)
        XCTAssertEqual(requestCoalescerRetryAfter(errorDescription: "FLOOD_PREMIUM_WAIT_10"), 10)
        XCTAssertEqual(requestCoalescerRetryAfter(errorDescription: "FLOOD_WAIT_X"), 0)
        XCTAssertEqual(requestCoalescerRetryAfter(errorDescription: "WALLET_UNAVAILABLE"), 0)
        XCTAssertEqual(requestCoalescerRetryAfter(errorDescription: nil), 0)
    }
}

final class RequestCoalescerSignalTests: XCTestCase {
    /// A fetch that counts how often it was started and answers when told to.
    private final class Fetch {
        var started = 0
        var subscribers: [Subscriber<(value: Int?, retryAfter: Double), NoError>] = []
        var signal: Signal<(value: Int?, retryAfter: Double), NoError> {
            return Signal { subscriber in
                self.started += 1
                self.subscribers.append(subscriber)
                return EmptyDisposable
            }
        }
        func answer(_ value: Int?, retryAfter: Double = 0) {
            for subscriber in self.subscribers {
                subscriber.putNext((value, retryAfter))
                subscriber.putCompletion()
            }
            self.subscribers = []
        }
    }

    private var clock: Double = 0

    private func makeCoalescer() -> RequestCoalescer<String, Int> {
        return RequestCoalescer<String, Int>(lifetime: 60, now: { return self.clock })
    }

    func testThreeIdenticalCallsWithinMillisecondsSendOneRequest() {
        let coalescer = self.makeCoalescer()
        let fetch = Fetch()
        var results: [Int] = []
        for _ in 0 ..< 3 {
            let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { results.append($0) })
        }
        XCTAssertEqual(fetch.started, 1)
        fetch.answer(7)
        XCTAssertEqual(results, [7, 7, 7])
    }

    func testSecondCallAfterTheAnswerUsesTheCacheUntilItExpires() {
        let coalescer = self.makeCoalescer()
        let fetch = Fetch()
        var results: [Int] = []
        let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { results.append($0) })
        fetch.answer(7)
        self.clock = 59
        let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { results.append($0) })
        XCTAssertEqual(fetch.started, 1)
        XCTAssertEqual(results, [7, 7])
        self.clock = 61
        let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { results.append($0) })
        XCTAssertEqual(fetch.started, 2)
    }

    func testInvalidateMakesTheNextCallAskAgain() {
        let coalescer = self.makeCoalescer()
        let fetch = Fetch()
        let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { _ in })
        fetch.answer(7)
        coalescer.invalidate(key: "a")
        let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { _ in })
        XCTAssertEqual(fetch.started, 2)
    }

    func testFailureAnswersTheFallbackAndFloodWaitHoldsBackTheNextRequest() {
        let coalescer = self.makeCoalescer()
        let fetch = Fetch()
        var results: [Int] = []
        let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { results.append($0) })
        fetch.answer(nil, retryAfter: 10)
        self.clock = 5
        let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { results.append($0) })
        XCTAssertEqual(fetch.started, 1)
        XCTAssertEqual(results, [-1, -1])
        self.clock = 10.5
        let _ = coalescer.signal(key: "a", fallback: -1, fetch: fetch.signal).start(next: { results.append($0) })
        XCTAssertEqual(fetch.started, 2)
    }

    func testDisposingEveryCallerCancelsTheFetchButOneRemainingCallerKeepsIt() {
        let coalescer = self.makeCoalescer()
        let cancelled = Atomic<Int>(value: 0)
        let fetch = Signal<(value: Int?, retryAfter: Double), NoError> { _ in
            return ActionDisposable { let _ = cancelled.modify { $0 + 1 } }
        }
        let first = coalescer.signal(key: "a", fallback: -1, fetch: fetch).start(next: { _ in })
        let second = coalescer.signal(key: "a", fallback: -1, fetch: fetch).start(next: { _ in })
        first.dispose()
        XCTAssertEqual(cancelled.with { $0 }, 0)
        second.dispose()
        XCTAssertEqual(cancelled.with { $0 }, 1)
    }
}
