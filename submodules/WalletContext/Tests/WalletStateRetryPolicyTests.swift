import XCTest
@testable import WalletContext

final class WalletStateRetryPolicyTests: XCTestCase {
    private func delays(count: Int, demand: Bool) -> [TimeInterval] {
        var policy = WalletStateRetryPolicy()
        var result: [TimeInterval] = []
        for _ in 0..<count {
            policy.recordFailure()
            result.append(policy.delay(hasRefreshDemand: demand))
        }
        return result
    }

    func testUnattendedDelayDoublesFromFiveSecondsAndStopsAtTenMinutes() {
        XCTAssertEqual(delays(count: 10, demand: false), [5, 10, 20, 40, 80, 160, 320, 600, 600, 600])
    }

    func testVisibleWalletCapsTheWait() {
        XCTAssertEqual(delays(count: 6, demand: true), [5, 10, 20, 20, 20, 20])
    }

    func testDemandAfterLongBackoffIsCappedImmediately() {
        var policy = WalletStateRetryPolicy()
        for _ in 0..<9 { policy.recordFailure() }
        XCTAssertEqual(policy.delay(hasRefreshDemand: false), 600)
        XCTAssertEqual(policy.delay(hasRefreshDemand: true), 20)
    }

    func testResetStartsOverAtFiveSeconds() {
        var policy = WalletStateRetryPolicy()
        policy.recordFailure()
        policy.recordFailure()
        policy.reset()
        policy.recordFailure()
        XCTAssertEqual(policy.delay(hasRefreshDemand: false), 5)
    }
}
