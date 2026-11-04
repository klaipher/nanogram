import XCTest
@testable import WalletContext

final class WalletStateRetryPolicyTests: XCTestCase {
    func testDelayDoublesFromFiveSecondsAndStopsAtTenMinutes() {
        var policy = WalletStateRetryPolicy()
        var delays: [TimeInterval] = []
        for _ in 0..<10 {
            policy.recordFailure()
            delays.append(policy.delay)
        }
        XCTAssertEqual(delays, [5, 10, 20, 40, 80, 160, 320, 600, 600, 600])
    }

    func testSuccessStartsOverAtFiveSeconds() {
        var policy = WalletStateRetryPolicy()
        policy.recordFailure()
        policy.recordFailure()
        policy.reset()
        policy.recordFailure()
        XCTAssertEqual(policy.delay, 5)
    }

    func testAnAccountWithoutAWalletAndWithoutDemandDoesNotRetry() {
        let policy = WalletStateRetryPolicy()
        XCTAssertFalse(policy.shouldRetry(hasWallet: false, hasRefreshDemand: false))
        XCTAssertTrue(policy.shouldRetry(hasWallet: false, hasRefreshDemand: true))
        XCTAssertTrue(policy.shouldRetry(hasWallet: true, hasRefreshDemand: false))
    }
}
