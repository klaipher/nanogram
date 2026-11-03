import Foundation
import XCTest
@testable import Postbox

final class RecentFileTouchesTests: XCTestCase {
    func testAPathTouchedRecentlyIsNotTouchedAgain() {
        var touches = RecentFileTouches(interval: 3600.0, maxCount: 100)
        XCTAssertEqual(Set(touches.pathsToTouch(["a", "b"], now: 1000.0)), ["a", "b"])
        XCTAssertEqual(touches.pathsToTouch(["a", "b"], now: 1010.0), [])
        XCTAssertEqual(touches.pathsToTouch(["a", "c"], now: 2000.0), ["c"])
        XCTAssertEqual(Set(touches.pathsToTouch(["a", "b", "c"], now: 1000.0 + 3600.0)), ["a", "b"])
    }

    func testTheDefaultThrottleStaysWellBelowTheShortLivedStoreTime() {
        let shortLivedMaxStoreTime: Double = 60.0 * 60.0
        XCTAssertLessThanOrEqual(RecentFileTouches.defaultInterval, shortLivedMaxStoreTime / 10.0)

        var touches = RecentFileTouches()
        XCTAssertEqual(touches.pathsToTouch(["a"], now: 0.0), ["a"])
        XCTAssertEqual(touches.pathsToTouch(["a"], now: 50.0 * 60.0), ["a"])
    }

    func testAClockGoingBackwardsTouchesAgain() {
        var touches = RecentFileTouches(interval: 3600.0, maxCount: 100)
        XCTAssertEqual(touches.pathsToTouch(["a"], now: 5000.0), ["a"])
        XCTAssertEqual(touches.pathsToTouch(["a"], now: 4000.0), ["a"])
    }

    func testOddClocksStillTouch() {
        var touches = RecentFileTouches(interval: 300.0, maxCount: 2)
        for now in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 0.0, Double.nan] {
            XCTAssertEqual(touches.pathsToTouch(["a", "b", "c"], now: now).count, 3, "\(now)")
        }
        XCTAssertLessThanOrEqual(touches.count, 2)
    }

    func testTheTouchMemoryStaysBounded() {
        var touches = RecentFileTouches(interval: 3600.0, maxCount: 1000)
        for i in 0 ..< 5 {
            let batch = Set((0 ..< 800).map { "p\(i)-\($0)" })
            XCTAssertEqual(touches.pathsToTouch(batch, now: 100.0 + Double(i)).count, 800)
            XCTAssertLessThanOrEqual(touches.count, 1000)
        }
    }
}
