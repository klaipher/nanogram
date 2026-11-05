import Foundation
import XCTest
@testable import Postbox

/// The cache walkers (the time-based cleanup scan and the automatic cache eviction) walk every cached file with
/// `stat`: seconds of CPU at launch. They run at most once a day, never in the first minute after launch, and
/// the file touches skip files that were touched recently.
final class CacheWalkerPolicyTests: XCTestCase {
    private let day: Double = 24.0 * 60.0 * 60.0

    // MARK: - Gate

    func testAWalkerThatNeverRanIsDue() {
        XCTAssertTrue(CacheWalkerGate.isDue(record: nil, fingerprint: "a", now: 1_000_000.0))
    }

    func testAWalkerThatRanLessThanADayAgoIsNotDue() {
        let record = CacheWalkerRecord(completedAt: 1_000_000.0, fingerprint: "a")
        XCTAssertFalse(CacheWalkerGate.isDue(record: record, fingerprint: "a", now: 1_000_000.0))
        XCTAssertFalse(CacheWalkerGate.isDue(record: record, fingerprint: "a", now: 1_000_000.0 + self.day - 1.0))
    }

    func testAWalkerThatRanADayAgoIsDue() {
        let record = CacheWalkerRecord(completedAt: 1_000_000.0, fingerprint: "a")
        XCTAssertTrue(CacheWalkerGate.isDue(record: record, fingerprint: "a", now: 1_000_000.0 + self.day))
        XCTAssertTrue(CacheWalkerGate.isDue(record: record, fingerprint: "a", now: 1_000_000.0 + 3.0 * self.day))
    }

    func testChangedLimitsMakeAWalkerDueAtOnce() {
        let record = CacheWalkerRecord(completedAt: 1_000_000.0, fingerprint: "a")
        XCTAssertTrue(CacheWalkerGate.isDue(record: record, fingerprint: "b", now: 1_000_010.0))
    }

    func testAClockSetBackwardsMakesAWalkerDue() {
        let record = CacheWalkerRecord(completedAt: 1_000_000.0, fingerprint: "a")
        XCTAssertTrue(CacheWalkerGate.isDue(record: record, fingerprint: "a", now: 900_000.0))
    }

    func testOddClocksAreDue() {
        let record = CacheWalkerRecord(completedAt: 1_000_000.0, fingerprint: "a")
        for now in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(CacheWalkerGate.isDue(record: record, fingerprint: "a", now: now), "\(now)")
        }
        let odd = CacheWalkerRecord(completedAt: .nan, fingerprint: "a")
        XCTAssertTrue(CacheWalkerGate.isDue(record: odd, fingerprint: "a", now: 1_000_000.0))
    }

    func testTheFirstRunWaitsAMinuteAfterLaunch() {
        XCTAssertEqual(CacheWalkerGate.delay(configured: 10.0, processStartTime: 1_000.0, now: 1_005.0), 55.0, accuracy: 0.001)
        XCTAssertEqual(CacheWalkerGate.delay(configured: 10.0, processStartTime: 1_000.0, now: 1_059.5), 10.0, accuracy: 0.001)
    }

    func testALateRunIsNotDelayedFurther() {
        XCTAssertEqual(CacheWalkerGate.delay(configured: 10.0, processStartTime: 1_000.0, now: 5_000.0), 10.0, accuracy: 0.001)
        XCTAssertEqual(CacheWalkerGate.delay(configured: 0.0, processStartTime: 1_000.0, now: 5_000.0), 0.0, accuracy: 0.001)
    }

    func testAConfiguredDelayLongerThanTheLaunchWindowWins() {
        XCTAssertEqual(CacheWalkerGate.delay(configured: 120.0, processStartTime: 1_000.0, now: 1_005.0), 120.0, accuracy: 0.001)
    }

    func testOddClocksFallBackToTheConfiguredDelay() {
        XCTAssertEqual(CacheWalkerGate.delay(configured: 10.0, processStartTime: .nan, now: 1_000.0), 10.0)
        XCTAssertEqual(CacheWalkerGate.delay(configured: 10.0, processStartTime: 1_000.0, now: .infinity), 10.0)
    }

    func testTheProcessStartTimeIsInThePastAndRecent() {
        let start = CacheWalkerGate.processStartTime
        let now = Date().timeIntervalSince1970
        XCTAssertLessThanOrEqual(start, now)
        XCTAssertGreaterThan(start, now - 7.0 * self.day)
    }

    // MARK: - Touch

    func testAFileTouchedRecentlyIsNotTouchedAgain() {
        XCTAssertFalse(CacheTouchPolicy.needsTouch(modificationTime: 1_000.0, now: 1_000.0 + 60.0, interval: 300.0))
        XCTAssertFalse(CacheTouchPolicy.needsTouch(modificationTime: 1_000.0, now: 1_000.0 + 299.0, interval: 300.0))
    }

    func testAFileNotTouchedForTheIntervalIsTouched() {
        XCTAssertTrue(CacheTouchPolicy.needsTouch(modificationTime: 1_000.0, now: 1_000.0 + 300.0, interval: 300.0))
        XCTAssertTrue(CacheTouchPolicy.needsTouch(modificationTime: 1_000.0, now: 1_000.0 + 86_400.0, interval: 300.0))
    }

    func testAMissingOrFutureModificationTimeIsTouched() {
        XCTAssertTrue(CacheTouchPolicy.needsTouch(modificationTime: nil, now: 1_000.0, interval: 300.0))
        XCTAssertTrue(CacheTouchPolicy.needsTouch(modificationTime: 5_000.0, now: 1_000.0, interval: 300.0))
        XCTAssertTrue(CacheTouchPolicy.needsTouch(modificationTime: .nan, now: 1_000.0, interval: 300.0))
        XCTAssertTrue(CacheTouchPolicy.needsTouch(modificationTime: 1_000.0, now: .nan, interval: 300.0))
    }

    func testTheTouchSkipStaysWellBelowTheShortLivedStoreTime() {
        // Short-lived files are removed one hour after their last use, so an mtime up to the interval stale is safe.
        XCTAssertLessThanOrEqual(CacheTouchPolicy.skipInterval, 60.0 * 60.0 / 10.0)
    }

    func testTouchesAreCountedByTheFileSystemNotTheMemory() throws {
        let path = NSTemporaryDirectory() + "CacheTouchPolicy-" + UUID().uuidString
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data([1])))
        defer {
            let _ = try? FileManager.default.removeItem(atPath: path)
        }
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(CacheTouchPolicy.touchNeeded(paths: [path], now: now), [])
        // A path that no longer exists has nothing to touch.
        XCTAssertEqual(CacheTouchPolicy.touchNeeded(paths: [path, path + ".missing"], now: now + 3600.0), [path])
    }
}
