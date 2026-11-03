import Foundation
import XCTest
@testable import TelegramCallsUI

/// The group call asks the server for the video of every tile it may show. Up to
/// `unlimitedTileCount` tiles nothing changes; above that only the tiles on screen, a margin of
/// `prefetchTiles` around them, and the expanded tile are asked for, so a large video chat does
/// not decode (and download) dozens of streams nobody sees.
final class VideoRequestPolicyTests: XCTestCase {
    func testSmallGridsRequestEveryTile() {
        for count in 0 ... VideoRequestPolicy.unlimitedTileCount {
            XCTAssertEqual(VideoRequestPolicy.requestedTileIndices(tileCount: count, visible: nil, forced: []), Set(0 ..< count))
            XCTAssertEqual(VideoRequestPolicy.requestedTileIndices(tileCount: count, visible: (0, 0), forced: []), Set(0 ..< count))
        }
    }

    func testLargeGridRequestsVisibleTilesPlusMargin() {
        let result = VideoRequestPolicy.requestedTileIndices(tileCount: 40, visible: (10, 13), forced: [])
        XCTAssertEqual(result, Set(8 ... 15))
    }

    func testMarginIsClampedToTheGrid() {
        XCTAssertEqual(VideoRequestPolicy.requestedTileIndices(tileCount: 40, visible: (0, 3), forced: []), Set(0 ... 5))
        XCTAssertEqual(VideoRequestPolicy.requestedTileIndices(tileCount: 40, visible: (36, 39), forced: []), Set(34 ... 39))
    }

    func testExpandedTileIsAlwaysRequested() {
        let result = VideoRequestPolicy.requestedTileIndices(tileCount: 40, visible: (0, 3), forced: [30])
        XCTAssertTrue(result.contains(30))
        XCTAssertTrue(result.contains(0))
        XCTAssertEqual(result.count, 7)
    }

    func testUnknownVisibilityRequestsTheLeadingTiles() {
        let result = VideoRequestPolicy.requestedTileIndices(tileCount: 40, visible: nil, forced: [])
        XCTAssertEqual(result, Set(0 ..< VideoRequestPolicy.unlimitedTileCount))
    }

    func testEmptyVisibleRangeFallsBackToTheLeadingTiles() {
        // visibleGridItemRange returns max < min when nothing is on screen.
        let result = VideoRequestPolicy.requestedTileIndices(tileCount: 40, visible: (5, 4), forced: [])
        XCTAssertEqual(result, Set(0 ..< VideoRequestPolicy.unlimitedTileCount))
    }

    func testOutOfRangeIndicesAreIgnored() {
        let result = VideoRequestPolicy.requestedTileIndices(tileCount: 10, visible: (8, 20), forced: [99, -1])
        XCTAssertEqual(result, Set(6 ... 9))
    }
}
