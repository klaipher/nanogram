import Foundation
import XCTest
@testable import TelegramCallsUI

/// The group call asks the server for the video of every tile it may show. Up to
/// `unlimitedTileCount` tiles nothing changes; above that only the tiles on screen, a margin of
/// `prefetchTiles` around them, and the expanded tile are asked for, so a large video chat does
/// not decode (and download) dozens of streams nobody sees.
final class VideoRequestPolicyTests: XCTestCase {
    /// With a tile expanded the strip of thumbnails shows everyone, so nobody may be left out of the request.
    func testNothingIsLimitedWhileATileIsExpanded() {
        XCTAssertTrue(VideoRequestPolicy.limitsRequestedTiles(tileCount: 40, hasExpandedTile: false))
        XCTAssertFalse(VideoRequestPolicy.limitsRequestedTiles(tileCount: 40, hasExpandedTile: true))
        XCTAssertFalse(VideoRequestPolicy.limitsRequestedTiles(tileCount: VideoRequestPolicy.unlimitedTileCount, hasExpandedTile: false))
    }

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

/// A tile that scrolls out of view is not dropped from the request at once: the engine destroys the receive
/// stream and decoder of a video that is no longer requested, and building it again waits for a keyframe. A
/// fling over a big grid used to create and destroy several decoders per second. Tiles are added immediately
/// and removed only after they have been unwanted for `removalDelay`.
final class VideoRequestRetentionTests: XCTestCase {
    func testWantedKeysAreRequestedAtOnce() {
        var retention = VideoRequestRetention<Int>()
        XCTAssertEqual(retention.requested(wanted: [1, 2, 3], now: 0.0), [1, 2, 3])
        XCTAssertEqual(retention.requested(wanted: [1, 2, 3, 4], now: 0.1), [1, 2, 3, 4])
    }

    func testAKeyThatLeavesIsKeptForTheDelay() {
        var retention = VideoRequestRetention<Int>()
        _ = retention.requested(wanted: [1, 2, 3], now: 0.0)
        XCTAssertEqual(retention.requested(wanted: [2, 3], now: 1.0), [1, 2, 3])
        XCTAssertEqual(retention.requested(wanted: [2, 3], now: 1.0 + VideoRequestRetention<Int>.removalDelay - 0.01), [1, 2, 3])
        XCTAssertEqual(retention.requested(wanted: [2, 3], now: 1.0 + VideoRequestRetention<Int>.removalDelay + 0.01), [2, 3])
    }

    /// Scrolling back before the delay ends keeps the same stream: nothing was ever removed.
    func testAKeyThatComesBackIsNeverRemoved() {
        var retention = VideoRequestRetention<Int>()
        _ = retention.requested(wanted: [1, 2], now: 0.0)
        _ = retention.requested(wanted: [2], now: 1.0)
        XCTAssertEqual(retention.requested(wanted: [1, 2], now: 2.0), [1, 2])
        // Its clock restarted: it leaves again at 3.0 and is kept until 3.0 + delay.
        XCTAssertEqual(retention.requested(wanted: [2], now: 3.0), [1, 2])
        XCTAssertEqual(retention.requested(wanted: [2], now: 3.0 + VideoRequestRetention<Int>.removalDelay - 0.01), [1, 2])
        XCTAssertEqual(retention.requested(wanted: [2], now: 3.0 + VideoRequestRetention<Int>.removalDelay + 0.01), [2])
    }

    func testNextExpiryTellsWhenToLookAgain() {
        var retention = VideoRequestRetention<Int>()
        XCTAssertNil(retention.nextExpiry())
        _ = retention.requested(wanted: [1, 2], now: 0.0)
        XCTAssertNil(retention.nextExpiry())
        _ = retention.requested(wanted: [2], now: 1.0)
        XCTAssertEqual(retention.nextExpiry()!, 1.0 + VideoRequestRetention<Int>.removalDelay, accuracy: 0.0001)
        _ = retention.requested(wanted: [2], now: 10.0)
        XCTAssertNil(retention.nextExpiry())
    }

    func testResetForgetsEverything() {
        var retention = VideoRequestRetention<Int>()
        _ = retention.requested(wanted: [1, 2], now: 0.0)
        retention.reset()
        XCTAssertEqual(retention.requested(wanted: [2], now: 0.5), [2])
    }
}
