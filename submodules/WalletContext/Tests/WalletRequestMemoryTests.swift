import XCTest
@testable import WalletContext

final class WalletRequestMemoryTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // (i) 65 foreground flips in 93 minutes collapse
    func testForegroundFlipsInsideTheIntervalRefreshOnce() {
        var throttle = WalletTonConnectRefreshThrottle()
        var sent = 0
        for flip in 0 ..< 65 {
            let now = start.addingTimeInterval(Double(flip) * 5)
            if throttle.shouldRefresh(isAutomatic: true, hasWalletScreen: false, now: now) {
                sent += 1
                throttle.recordSuccess(at: now)
            }
        }
        XCTAssertEqual(sent, 2, "5 s x 65 flips = 325 s: one refresh at the start and one after 300 s")
    }

    func testFirstAutomaticRefreshAfterLaunchRuns() {
        XCTAssertTrue(WalletTonConnectRefreshThrottle().shouldRefresh(isAutomatic: true, hasWalletScreen: false, now: start))
    }

    // (ii) bypassed by screens and explicit refreshes
    func testOpenWalletScreenRefreshesAsBefore() {
        var throttle = WalletTonConnectRefreshThrottle()
        throttle.recordSuccess(at: start)
        XCTAssertTrue(throttle.shouldRefresh(isAutomatic: true, hasWalletScreen: true, now: start.addingTimeInterval(1)))
    }

    func testExplicitRefreshIsNeverHeldBack() {
        var throttle = WalletTonConnectRefreshThrottle()
        throttle.recordSuccess(at: start)
        XCTAssertTrue(throttle.shouldRefresh(isAutomatic: false, hasWalletScreen: false, now: start.addingTimeInterval(1)))
    }

    func testResetRefreshesAtOnce() {
        var throttle = WalletTonConnectRefreshThrottle()
        throttle.recordSuccess(at: start)
        throttle.reset()
        XCTAssertTrue(throttle.shouldRefresh(isAutomatic: true, hasWalletScreen: false, now: start.addingTimeInterval(1)))
    }

    // (iii) expiry
    func testAutomaticRefreshRunsAgainAfterTheInterval() {
        var throttle = WalletTonConnectRefreshThrottle()
        throttle.recordSuccess(at: start)
        XCTAssertFalse(throttle.shouldRefresh(isAutomatic: true, hasWalletScreen: false, now: start.addingTimeInterval(299)))
        XCTAssertTrue(throttle.shouldRefresh(isAutomatic: true, hasWalletScreen: false, now: start.addingTimeInterval(300)))
    }

    func testClockGoingBackwardsRefreshes() {
        var throttle = WalletTonConnectRefreshThrottle()
        throttle.recordSuccess(at: start)
        XCTAssertTrue(throttle.shouldRefresh(isAutomatic: true, hasWalletScreen: false, now: start.addingTimeInterval(-10)))
    }

    func testUnavailableAnswerIsRememberedForFiveMinutes() {
        let stored = start.timeIntervalSince1970
        XCTAssertEqual(WalletUnavailableMemory.rememberedAnswerDate(stored: stored, now: start.addingTimeInterval(24)), Date(timeIntervalSince1970: stored))
        XCTAssertNotNil(WalletUnavailableMemory.rememberedAnswerDate(stored: stored, now: start.addingTimeInterval(299)))
        XCTAssertNil(WalletUnavailableMemory.rememberedAnswerDate(stored: stored, now: start.addingTimeInterval(300)))
    }

    func testNothingStoredOrStoredInTheFutureIsNotRemembered() {
        XCTAssertNil(WalletUnavailableMemory.rememberedAnswerDate(stored: nil, now: start))
        XCTAssertNil(WalletUnavailableMemory.rememberedAnswerDate(stored: start.timeIntervalSince1970 + 60, now: start))
    }

    // a remembered answer makes the retry policy start out stopped; opening the wallet asks at once
    func testRememberedAnswerStopsAutomaticRequestsUntilTheWalletIsOpened() {
        var policy = WalletStateRetryPolicy()
        policy.recordFailure(.authoritative, at: start)
        let now = start.addingTimeInterval(30)
        guard case .wait = policy.gate(hasRefreshDemand: false, now: now) else {
            return XCTFail("an automatic request right after the remembered answer must wait")
        }
        policy.resetForUserDemand()
        XCTAssertEqual(policy.gate(hasRefreshDemand: true, now: now), .allow)
    }
}
