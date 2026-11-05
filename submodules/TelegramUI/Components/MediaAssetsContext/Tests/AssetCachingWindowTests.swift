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
}
