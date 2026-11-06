import Foundation
import XCTest
@testable import MediaAssetsContext

final class AssetCachingWindowTests: XCTestCase {
    func testWindowAddsOneScreenOnEachSide() {
        XCTAssertEqual(AssetCachingWindow.window(visible: 100 ... 119, count: 1000), 80 ..< 140)
    }

    func testWindowIsClampedToTheFetchResult() {
        XCTAssertEqual(AssetCachingWindow.window(visible: 0 ... 19, count: 1000), 0 ..< 40)
        XCTAssertEqual(AssetCachingWindow.window(visible: 990 ... 999, count: 1000), 980 ..< 1000)
        XCTAssertEqual(AssetCachingWindow.window(visible: 0 ... 5, count: 0), 0 ..< 0)
        XCTAssertEqual(AssetCachingWindow.window(visible: 50 ... 60, count: 10), 0 ..< 0)
    }

    func testFirstWindowStartsEverything() {
        let result = AssetCachingWindow.diff(previous: nil, next: 80 ..< 140)
        XCTAssertEqual(result.start, [80 ..< 140])
        XCTAssertTrue(result.stop.isEmpty)
    }

    func testScrollingDownStartsTheNewEdgeAndStopsTheOldOne() {
        let result = AssetCachingWindow.diff(previous: 80 ..< 140, next: 100 ..< 160)
        XCTAssertEqual(result.start, [140 ..< 160])
        XCTAssertEqual(result.stop, [80 ..< 100])
    }

    func testUnchangedWindowDoesNothing() {
        let result = AssetCachingWindow.diff(previous: 80 ..< 140, next: 80 ..< 140)
        XCTAssertTrue(result.start.isEmpty)
        XCTAssertTrue(result.stop.isEmpty)
    }

    func testJumpDoesNotOverlap() {
        let result = AssetCachingWindow.diff(previous: 0 ..< 40, next: 500 ..< 540)
        XCTAssertEqual(result.start, [500 ..< 540])
        XCTAssertEqual(result.stop, [0 ..< 40])
    }

    func testGrowingWindowStartsBothSides() {
        let result = AssetCachingWindow.diff(previous: 100 ..< 120, next: 90 ..< 130)
        XCTAssertEqual(result.start, [90 ..< 100, 120 ..< 130])
        XCTAssertTrue(result.stop.isEmpty)
    }

    func testClearingStopsEverything() {
        let result = AssetCachingWindow.diff(previous: 80 ..< 140, next: nil)
        XCTAssertTrue(result.start.isEmpty)
        XCTAssertEqual(result.stop, [80 ..< 140])
    }

    func testDirectionalWindowReachesAScreenAheadAndHalfBehind() {
        XCTAssertEqual(AssetCachingWindow.directionalWindow(visible: 100 ... 119, count: 1000, direction: 1), 90 ..< 140)
        XCTAssertEqual(AssetCachingWindow.directionalWindow(visible: 100 ... 119, count: 1000, direction: -1), 80 ..< 130)
        XCTAssertEqual(AssetCachingWindow.directionalWindow(visible: 100 ... 119, count: 1000, direction: 0), 90 ..< 130)
    }

    func testDirectionalWindowIsClamped() {
        XCTAssertEqual(AssetCachingWindow.directionalWindow(visible: 0 ... 19, count: 1000, direction: -1), 0 ..< 30)
        XCTAssertEqual(AssetCachingWindow.directionalWindow(visible: 990 ... 999, count: 1000, direction: 1), 985 ..< 1000)
        XCTAssertEqual(AssetCachingWindow.directionalWindow(visible: 0 ... 5, count: 0, direction: 1), 0 ..< 0)
        XCTAssertEqual(AssetCachingWindow.directionalWindow(visible: 50 ... 60, count: 10, direction: 1), 0 ..< 0)
    }

    func testDirectionFollowsTheFirstVisibleIndex() {
        XCTAssertEqual(AssetCachingWindow.direction(previousLower: nil, lower: 10, previousDirection: 0), 0)
        XCTAssertEqual(AssetCachingWindow.direction(previousLower: 10, lower: 14, previousDirection: 0), 1)
        XCTAssertEqual(AssetCachingWindow.direction(previousLower: 14, lower: 9, previousDirection: 1), -1)
        XCTAssertEqual(AssetCachingWindow.direction(previousLower: 9, lower: 9, previousDirection: -1), -1)
    }
}
