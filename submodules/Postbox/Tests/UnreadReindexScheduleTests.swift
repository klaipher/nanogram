import XCTest
@testable import Postbox

/// Upstream reindexes unread counts on every launch (its `#if DEBUG` guard is commented out): ~30-50 ms on the Postbox
/// queue and ~10 MB of WAL per launch, and iOS relaunches the app many times a day. A version change still reindexes at
/// once; otherwise at most every 6 hours.
final class UnreadReindexScheduleTests: XCTestCase {
    func testAVersionChangeAlwaysReindexes() {
        XCTAssertTrue(PostboxUnreadReindexSchedule.shouldForceReindex(versionChanged: true, lastRun: 1000.0, now: 1001.0))
    }

    func testTheFirstLaunchReindexes() {
        XCTAssertTrue(PostboxUnreadReindexSchedule.shouldForceReindex(versionChanged: false, lastRun: nil, now: 1000.0))
    }

    func testARecentReindexIsNotRepeated() {
        XCTAssertFalse(PostboxUnreadReindexSchedule.shouldForceReindex(versionChanged: false, lastRun: 1000.0, now: 1000.0 + 5.0 * 3600.0))
    }

    func testAnOldReindexIsRepeated() {
        XCTAssertTrue(PostboxUnreadReindexSchedule.shouldForceReindex(versionChanged: false, lastRun: 1000.0, now: 1000.0 + 6.0 * 3600.0))
    }

    func testAClockThatWentBackwardsDoesNotBlock() {
        XCTAssertTrue(PostboxUnreadReindexSchedule.shouldForceReindex(versionChanged: false, lastRun: 5000.0, now: 1000.0))
    }

    func testTheMarkerRoundTrips() {
        let path = NSTemporaryDirectory() + "UnreadReindexScheduleTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(PostboxUnreadReindexSchedule.lastRun(markerPath: path))
        PostboxUnreadReindexSchedule.setLastRun(markerPath: path, timestamp: 1234.5)
        XCTAssertEqual(PostboxUnreadReindexSchedule.lastRun(markerPath: path), 1234.5)
    }
}
