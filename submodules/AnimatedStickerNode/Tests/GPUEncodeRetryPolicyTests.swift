import Foundation
import XCTest
@testable import AnimatedStickerNode

final class GPUEncodeRetryPolicyTests: XCTestCase {
    func testAFreshPolicyAttemptsEveryFrame() {
        let policy = GPUEncodeRetryPolicy()
        XCTAssertTrue(policy.shouldAttempt(index: 0))
        XCTAssertTrue(policy.shouldAttempt(index: 41))
        XCTAssertFalse(policy.isGPUDisabled)
    }

    func testAFrameIsGivenUpAfterThreeFailures() {
        var policy = GPUEncodeRetryPolicy()
        for _ in 0 ..< GPUEncodeRetryPolicy.maxFailuresPerIndex - 1 {
            policy.recordFailure(index: 5)
            XCTAssertTrue(policy.shouldAttempt(index: 5))
        }
        policy.recordFailure(index: 5)
        XCTAssertFalse(policy.shouldAttempt(index: 5))
        XCTAssertTrue(policy.shouldAttempt(index: 6), "other frames are still tried")
        XCTAssertFalse(policy.isGPUDisabled)
    }

    func testTheGPUIsGivenUpAfterEightFailuresInTotal() {
        var policy = GPUEncodeRetryPolicy()
        var disabledAt: [Int] = []
        for i in 0 ..< 8 {
            if policy.recordFailure(index: i) {
                disabledAt.append(i)
            }
        }
        XCTAssertTrue(policy.isGPUDisabled)
        XCTAssertEqual(disabledAt, [7], "reported once, by the eighth failure")
        XCTAssertFalse(policy.shouldAttempt(index: 100))
        XCTAssertFalse(policy.recordFailure(index: 100), "not reported again")
    }

    func testASuccessClearsTheFramesFailuresButNotTheTotal() {
        var policy = GPUEncodeRetryPolicy()
        policy.recordFailure(index: 3)
        policy.recordFailure(index: 3)
        policy.recordSuccess(index: 3)
        XCTAssertEqual(policy.totalFailures, 2)
        policy.recordFailure(index: 3)
        policy.recordFailure(index: 3)
        XCTAssertTrue(policy.shouldAttempt(index: 3), "two failures since the success")
        policy.recordFailure(index: 3)
        XCTAssertFalse(policy.shouldAttempt(index: 3))
    }

    func testTheLimitsAreAsPlanned() {
        XCTAssertEqual(GPUEncodeRetryPolicy.maxFailuresPerIndex, 3)
        XCTAssertEqual(GPUEncodeRetryPolicy.maxFailuresInTotal, 8)
    }
}
