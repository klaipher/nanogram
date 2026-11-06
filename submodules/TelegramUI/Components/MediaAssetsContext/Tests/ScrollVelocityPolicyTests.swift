import Foundation
import XCTest
@testable import MediaAssetsContext

final class ScrollVelocityPolicyTests: XCTestCase {
    private struct Cursor {
        var time: Double
        var offset: Double
    }

    private func feed(_ estimator: inout ScrollVelocityEstimator, speed: Double, from cursor: Cursor, ticks: Int) -> Cursor {
        var cursor = cursor
        for _ in 0 ..< ticks {
            cursor.time += 1.0 / 60.0
            cursor.offset += speed / 60.0
            estimator.note(offset: cursor.offset, time: cursor.time)
        }
        return cursor
    }

    func testSlowScrollIsNotAFling() {
        var estimator = ScrollVelocityEstimator()
        let end = feed(&estimator, speed: 600.0, from: Cursor(time: 0.0, offset: 0.0), ticks: 30)
        XCTAssertFalse(estimator.isFlinging(at: end.time))
    }

    func testFastScrollIsAFlingAndEndsWithHysteresis() {
        var estimator = ScrollVelocityEstimator()
        var end = feed(&estimator, speed: 4000.0, from: Cursor(time: 0.0, offset: 0.0), ticks: 20)
        XCTAssertTrue(estimator.isFlinging(at: end.time))
        // Between the two thresholds the state holds.
        end = feed(&estimator, speed: 1800.0, from: end, ticks: 20)
        XCTAssertTrue(estimator.isFlinging(at: end.time))
        end = feed(&estimator, speed: 500.0, from: end, ticks: 20)
        XCTAssertFalse(estimator.isFlinging(at: end.time))
    }

    func testDirectionDoesNotMatter() {
        var estimator = ScrollVelocityEstimator()
        let end = feed(&estimator, speed: -4000.0, from: Cursor(time: 0.0, offset: 100000.0), ticks: 20)
        XCTAssertTrue(estimator.isFlinging(at: end.time))
    }

    func testAStaleSampleMeansStopped() {
        var estimator = ScrollVelocityEstimator()
        let end = feed(&estimator, speed: 4000.0, from: Cursor(time: 0.0, offset: 0.0), ticks: 20)
        XCTAssertTrue(estimator.isFlinging(at: end.time))
        XCTAssertFalse(estimator.isFlinging(at: end.time + 0.5))
        XCTAssertEqual(estimator.speed(at: end.time + 0.5), 0.0)
    }

    func testBadInputIsIgnored() {
        var estimator = ScrollVelocityEstimator()
        estimator.note(offset: .nan, time: 1.0)
        estimator.note(offset: 0.0, time: .infinity)
        XCTAssertEqual(estimator.speed(at: 1.0), 0.0)
        XCTAssertFalse(estimator.isFlinging(at: 1.0))
    }
}
