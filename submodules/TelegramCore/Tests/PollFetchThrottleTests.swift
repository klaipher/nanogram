import XCTest
@testable import TelegramCore

final class PollFetchThrottleTests: XCTestCase {
    private typealias Throttle = PollFetchThrottle<Int, String>

    func testFirstSightingFetches() {
        let throttle = Throttle(window: 60)
        XCTAssertTrue(throttle.shouldFetch(key: 1, fingerprint: "a", now: 0))
    }

    // (i) the repeated fetches of an unchanged poll collapse
    func testRepeatedVisibilityOfAnUnchangedPollFetchesOnce() {
        var throttle = Throttle(window: 60)
        var sent = 0
        for second in stride(from: 0.0, to: 59.0, by: 3.0) {
            if throttle.shouldFetch(key: 1, fingerprint: "a", now: second) {
                sent += 1
                throttle.recordFetch(key: 1, fingerprint: "a", now: second)
            }
        }
        XCTAssertEqual(sent, 1)
    }

    func testOtherPollsAreIndependent() {
        var throttle = Throttle(window: 60)
        throttle.recordFetch(key: 1, fingerprint: "a", now: 0)
        XCTAssertTrue(throttle.shouldFetch(key: 2, fingerprint: "a", now: 1))
    }

    // (ii) bypassed after a change or a user action
    func testChangedStoredPollFetches() {
        var throttle = Throttle(window: 60)
        throttle.recordFetch(key: 1, fingerprint: "a", now: 0)
        XCTAssertTrue(throttle.shouldFetch(key: 1, fingerprint: "voted", now: 1))
    }

    func testUserActionFetchesAtOnce() {
        var throttle = Throttle(window: 60)
        throttle.recordFetch(key: 1, fingerprint: "a", now: 0)
        throttle.forget(key: 1)
        XCTAssertTrue(throttle.shouldFetch(key: 1, fingerprint: "a", now: 1))
    }

    // (iii) time-based expiry
    func testFetchesAgainOnceTheWindowHasElapsed() {
        var throttle = Throttle(window: 60)
        throttle.recordFetch(key: 1, fingerprint: "a", now: 10)
        XCTAssertFalse(throttle.shouldFetch(key: 1, fingerprint: "a", now: 69.9))
        XCTAssertTrue(throttle.shouldFetch(key: 1, fingerprint: "a", now: 70))
    }

    func testClockGoingBackwardsFetches() {
        var throttle = Throttle(window: 60)
        throttle.recordFetch(key: 1, fingerprint: "a", now: 100)
        XCTAssertTrue(throttle.shouldFetch(key: 1, fingerprint: "a", now: 50))
    }

    func testOldRecordsArePruned() {
        var throttle = Throttle(window: 60)
        for i in 0 ..< 300 {
            throttle.recordFetch(key: i, fingerprint: "a", now: 0)
        }
        throttle.recordFetch(key: 1000, fingerprint: "a", now: 1000)
        XCTAssertEqual(throttle.recordCount, 1)
    }
}
