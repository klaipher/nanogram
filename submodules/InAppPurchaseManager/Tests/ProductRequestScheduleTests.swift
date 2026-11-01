import XCTest
import InAppPurchaseManager

// Product requests are retried while there are no products, but only in the foreground: each StoreKit
// request holds a background task of its own, so a retry loop in the background keeps the app from being
// suspended (seen on device: requests every 20-50 s kept it awake for minutes after it was left).
final class ProductRequestScheduleTests: XCTestCase {
    typealias Schedule = InAppPurchaseProductRequestSchedule

    func testFirstRequestStartsInForeground() {
        var schedule = Schedule(isInBackground: false)
        XCTAssertEqual(schedule.requestNeeded(force: false), [.startRequest])
        XCTAssertEqual(schedule.requestNeeded(force: false), [], "one request at a time")
    }

    func testFirstRequestWaitsForForegroundWhenLaunchedInBackground() {
        var schedule = Schedule(isInBackground: true)
        XCTAssertEqual(schedule.requestNeeded(force: false), [])
        XCTAssertEqual(schedule.enteredForeground(), [.startRequest])
    }

    func testRetryDelays() {
        var schedule = Schedule(isInBackground: false)
        var delays: [Double] = []
        let _ = schedule.requestNeeded(force: false)
        for _ in 0 ..< 7 {
            let actions = schedule.requestFinished(receivedProducts: false)
            guard case let .scheduleRetry(delay)? = actions.first else {
                return XCTFail("expected a retry, got \(actions)")
            }
            delays.append(delay)
            XCTAssertEqual(schedule.retryFired(), [.startRequest])
        }
        XCTAssertEqual(delays, [10.0, 20.0, 40.0, 80.0, 160.0, 300.0, 300.0])
    }

    func testNoRetryInBackground() {
        var schedule = Schedule(isInBackground: false)
        let _ = schedule.requestNeeded(force: false)
        XCTAssertEqual(schedule.enteredBackground(), [.cancelRequest], "a request in flight holds a background task")
        XCTAssertEqual(schedule.requestFinished(receivedProducts: false), [], "a late answer to it starts nothing")
        XCTAssertEqual(schedule.requestNeeded(force: false), [])
        XCTAssertEqual(schedule.requestNeeded(force: true), [], "not even a forced one")
        XCTAssertEqual(schedule.enteredForeground(), [.startRequest])
    }

    func testPendingRetryIsCancelledInBackgroundAndResumedInForeground() {
        var schedule = Schedule(isInBackground: false)
        let _ = schedule.requestNeeded(force: false)
        let _ = schedule.requestFinished(receivedProducts: false)
        let _ = schedule.retryFired()
        XCTAssertEqual(schedule.requestFinished(receivedProducts: false), [.scheduleRetry(20.0)])
        XCTAssertEqual(schedule.enteredBackground(), [.cancelRetry])
        XCTAssertEqual(schedule.retryFired(), [], "a timer that fires late after the cancel starts nothing")
        XCTAssertEqual(schedule.enteredForeground(), [.scheduleRetry(20.0)], "the backoff is kept")
    }

    func testFailureInBackgroundIsRetriedInForeground() {
        var schedule = Schedule(isInBackground: false)
        let _ = schedule.requestNeeded(force: false)
        let _ = schedule.enteredBackground()
        let _ = schedule.enteredForeground()
        XCTAssertEqual(schedule.requestFinished(receivedProducts: false), [.scheduleRetry(10.0)])
    }

    func testForcedRequestReplacesPendingRetry() {
        var schedule = Schedule(isInBackground: false)
        let _ = schedule.requestNeeded(force: false)
        XCTAssertEqual(schedule.requestFinished(receivedProducts: false), [.scheduleRetry(10.0)])
        XCTAssertEqual(schedule.requestNeeded(force: false), [], "an unforced request waits for the retry")
        XCTAssertEqual(schedule.requestNeeded(force: true), [.cancelRetry, .startRequest], "a screen that shows prices asks now")
        XCTAssertEqual(schedule.retryFired(), [])
    }

    func testNothingAfterProducts() {
        var schedule = Schedule(isInBackground: false)
        let _ = schedule.requestNeeded(force: false)
        XCTAssertEqual(schedule.requestFinished(receivedProducts: true), [])
        XCTAssertEqual(schedule.requestNeeded(force: true), [])
        XCTAssertEqual(schedule.enteredBackground(), [])
        XCTAssertEqual(schedule.enteredForeground(), [])
        XCTAssertEqual(schedule.retryFired(), [])
    }

    func testForegroundWithoutPendingWorkDoesNothing() {
        var schedule = Schedule(isInBackground: false)
        XCTAssertEqual(schedule.enteredBackground(), [])
        XCTAssertEqual(schedule.enteredForeground(), [], "nothing was asked for yet")
    }

    func testRepeatedTransitionsDoNotStackRequests() {
        var schedule = Schedule(isInBackground: false)
        let _ = schedule.requestNeeded(force: false)
        let _ = schedule.enteredBackground()
        XCTAssertEqual(schedule.enteredForeground(), [.startRequest])
        XCTAssertEqual(schedule.enteredForeground(), [])
        XCTAssertEqual(schedule.enteredBackground(), [.cancelRequest])
        XCTAssertEqual(schedule.enteredBackground(), [])
    }
}
