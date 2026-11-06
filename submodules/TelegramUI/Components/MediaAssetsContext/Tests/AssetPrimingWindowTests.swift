import XCTest
@testable import MediaAssetsContext

final class AssetPrimingWindowTests: XCTestCase {
    func testEmptyResultPrimesNothing() {
        XCTAssertTrue(AssetPrimingWindow.ranges(count: 0).isEmpty)
        XCTAssertTrue(AssetPrimingWindow.ranges(count: 10, perEnd: 0).isEmpty)
    }

    func testSmallResultIsLoadedWhole() {
        XCTAssertEqual(AssetPrimingWindow.ranges(count: 5, perEnd: 48), [0 ..< 5])
        XCTAssertEqual(AssetPrimingWindow.ranges(count: 96, perEnd: 48), [0 ..< 96])
    }

    func testLargeResultLoadsBothEnds() {
        XCTAssertEqual(AssetPrimingWindow.ranges(count: 5000, perEnd: 48), [0 ..< 48, 4952 ..< 5000])
        XCTAssertEqual(AssetPrimingWindow.ranges(count: 97, perEnd: 48), [0 ..< 48, 49 ..< 97])
    }
}
