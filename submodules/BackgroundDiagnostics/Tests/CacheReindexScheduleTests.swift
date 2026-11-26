import XCTest
@testable import BackgroundDiagnostics

final class CacheReindexScheduleTests: XCTestCase {
    private let day = 24 * 60 * 60
    // A CFAbsoluteTime in late 2026, in seconds.
    private let now = 817_000_000

    func testKeyStaysTheOneExistingInstallsHave() {
        // Upstream and every earlier build store the last reindex time under this key; renaming it would rescan once.
        XCTAssertEqual(CacheReindexSchedule.timestampKey, "TelegramCacheIndexTimestamp_v2")
    }

    func testDueWhenNeverIndexed() {
        XCTAssertTrue(CacheReindexSchedule.isDue(lastIndexTimestamp: nil, now: self.now))
    }

    func testNotDueHoursAfterTheBackgroundTaskIndexed() {
        // The tester's case: the cleanup task finished at 00:37, the app launched at 13:01.
        XCTAssertFalse(CacheReindexSchedule.isDue(lastIndexTimestamp: self.now - 12 * 60 * 60, now: self.now))
        XCTAssertFalse(CacheReindexSchedule.isDue(lastIndexTimestamp: self.now - self.day, now: self.now))
    }

    func testDueAfterTwoDays() {
        XCTAssertFalse(CacheReindexSchedule.isDue(lastIndexTimestamp: self.now - 2 * self.day, now: self.now))
        XCTAssertTrue(CacheReindexSchedule.isDue(lastIndexTimestamp: self.now - 2 * self.day - 1, now: self.now))
        XCTAssertTrue(CacheReindexSchedule.isDue(lastIndexTimestamp: self.now - 3 * self.day, now: self.now))
    }

    func testExtremeStoredValuesDoNotTrap() {
        // The stored value is whatever an earlier build or a restored backup left there.
        XCTAssertTrue(CacheReindexSchedule.isDue(lastIndexTimestamp: Int.min, now: self.now))
        XCTAssertTrue(CacheReindexSchedule.isDue(lastIndexTimestamp: 0, now: self.now))
        XCTAssertFalse(CacheReindexSchedule.isDue(lastIndexTimestamp: Int.max, now: self.now))
        XCTAssertFalse(CacheReindexSchedule.isDue(lastIndexTimestamp: self.now, now: Int.min))
        XCTAssertFalse(CacheReindexSchedule.isDue(lastIndexTimestamp: Int.max, now: Int.max))
    }
}
