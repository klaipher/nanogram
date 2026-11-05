import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// The scheduled scan of the time-based cleanup walks every cached file. With the gate on (the app's setting) it
/// runs once a day at most, again when the limits change, never earlier than a minute after the process started,
/// and an explicit `rescan()` always runs.
final class TimeBasedCleanupGateTests: XCTestCase {
    private var basePath: String!
    private var mediaPath: String!
    private var logLines: Atomic<[String]>!
    private var storageBox: StorageBox!
    private var cacheStorageBox: StorageBox!

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "TimeBasedCleanupGateTests-" + UUID().uuidString
        self.mediaPath = self.basePath + "/media"
        for directory in [self.mediaPath!, self.mediaPath + "/cache", self.mediaPath + "/animation-cache", self.mediaPath + "/short-cache"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        TempBox.initializeShared(basePath: self.basePath + "/tempbox", processType: "test", launchSpecificId: 1)

        let logLines = Atomic<[String]>(value: [])
        self.logLines = logLines
        setPostboxLogger({ line in
            let _ = logLines.modify { $0 + [line] }
        }, sync: {})

        self.storageBox = StorageBox(logger: StorageBox.Logger(impl: { _ in }), basePath: self.basePath + "/storage", isMainProcess: true)
        self.cacheStorageBox = StorageBox(logger: StorageBox.Logger(impl: { _ in }), basePath: self.basePath + "/cache-storage", isMainProcess: true)
    }

    override func tearDown() {
        for box in [self.storageBox!, self.cacheStorageBox!] {
            let semaphore = DispatchSemaphore(value: 0)
            let disposable = box.all().start(next: { _ in
                semaphore.signal()
            })
            _ = semaphore.wait(timeout: .now() + 30.0)
            disposable.dispose()
        }
        setPostboxLogger({ _ in }, sync: {})
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func makeCleanup(processStartTime: Double = 0.0) -> TimeBasedCleanup {
        return TimeBasedCleanup(storageBox: self.storageBox, cacheStorageBox: self.cacheStorageBox, generalPaths: [
            self.mediaPath + "/cache",
            self.mediaPath + "/animation-cache"
        ], totalSizeBasedPath: self.mediaPath, shortLivedPaths: [
            self.mediaPath + "/short-cache"
        ], scanDelay: 0.0, gatesScans: true, processStartTime: processStartTime)
    }

    private func finishedScanCount() -> Int {
        return self.logLines.with { lines in
            return lines.filter { $0.contains("TimeBasedCleanup: scan id: ") && $0.contains(" finished") }.count
        }
    }

    private func skippedScanCount() -> Int {
        return self.logLines.with { lines in
            return lines.filter { $0.contains("TimeBasedCleanup: scan skipped") }.count
        }
    }

    private func waitUntil(timeout: Double = 60.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func record() -> CacheWalkerRecord? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: CacheWalkerRecord?
        let disposable = self.storageBox.cacheWalkerRecord(name: CacheWalkerName.timeBasedCleanup).start(next: { value in
            result = value
            semaphore.signal()
        })
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10.0), .success)
        disposable.dispose()
        return result
    }

    private func setRecord(_ record: CacheWalkerRecord) {
        self.storageBox.setCacheWalkerRecord(record, name: CacheWalkerName.timeBasedCleanup)
        // The write is queued behind nothing else on the box; reading it back orders it.
        XCTAssertTrue(self.waitUntil(timeout: 10.0, { self.record() == record }))
    }

    private let limits: (general: Int32, shortLived: Int32, gigabytes: Int32) = (30 * 86_400, 3_600, 5)

    func testTheFirstLaunchScansAndRecordsTheRun() {
        let cleanup = self.makeCleanup()
        cleanup.setMaxStoreTimes(general: self.limits.general, shortLived: self.limits.shortLived, gigabytesLimit: self.limits.gigabytes)

        XCTAssertTrue(self.waitUntil({ self.finishedScanCount() == 1 && self.record() != nil }))
        let recorded = self.record()
        XCTAssertEqual(recorded?.fingerprint, "\(self.limits.general),\(self.limits.shortLived),\(self.limits.gigabytes)")
        XCTAssertLessThan(abs((recorded?.completedAt ?? 0.0) - Date().timeIntervalSince1970), 60.0)
        withExtendedLifetime(cleanup) {}
    }

    func testARelaunchWithinADayDoesNotScanAgain() {
        self.setRecord(CacheWalkerRecord(completedAt: Date().timeIntervalSince1970 - 3600.0, fingerprint: "\(self.limits.general),\(self.limits.shortLived),\(self.limits.gigabytes)"))

        let cleanup = self.makeCleanup()
        cleanup.setMaxStoreTimes(general: self.limits.general, shortLived: self.limits.shortLived, gigabytesLimit: self.limits.gigabytes)

        XCTAssertTrue(self.waitUntil({ self.skippedScanCount() == 1 }))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(self.finishedScanCount(), 0)
        withExtendedLifetime(cleanup) {}
    }

    func testARunMoreThanADayAgoScansAgain() {
        self.setRecord(CacheWalkerRecord(completedAt: Date().timeIntervalSince1970 - 2.0 * 86_400.0, fingerprint: "\(self.limits.general),\(self.limits.shortLived),\(self.limits.gigabytes)"))

        let cleanup = self.makeCleanup()
        cleanup.setMaxStoreTimes(general: self.limits.general, shortLived: self.limits.shortLived, gigabytesLimit: self.limits.gigabytes)

        XCTAssertTrue(self.waitUntil({ self.finishedScanCount() == 1 }))
        withExtendedLifetime(cleanup) {}
    }

    func testChangedLimitsScanAtOnceEvenWithinADay() {
        self.setRecord(CacheWalkerRecord(completedAt: Date().timeIntervalSince1970 - 60.0, fingerprint: "\(self.limits.general),\(self.limits.shortLived),\(self.limits.gigabytes)"))

        let cleanup = self.makeCleanup()
        cleanup.setMaxStoreTimes(general: self.limits.general, shortLived: self.limits.shortLived, gigabytesLimit: self.limits.gigabytes + 1)

        XCTAssertTrue(self.waitUntil({ self.finishedScanCount() == 1 }))
        withExtendedLifetime(cleanup) {}
    }

    func testAnExplicitRescanIgnoresTheGate() {
        self.setRecord(CacheWalkerRecord(completedAt: Date().timeIntervalSince1970 - 60.0, fingerprint: "\(self.limits.general),\(self.limits.shortLived),\(self.limits.gigabytes)"))

        let cleanup = self.makeCleanup()
        cleanup.setMaxStoreTimes(general: self.limits.general, shortLived: self.limits.shortLived, gigabytesLimit: self.limits.gigabytes)
        XCTAssertTrue(self.waitUntil({ self.skippedScanCount() == 1 }))

        let semaphore = DispatchSemaphore(value: 0)
        let disposable = cleanup.rescan().start(completed: {
            semaphore.signal()
        })
        XCTAssertEqual(semaphore.wait(timeout: .now() + 60.0), .success)
        disposable.dispose()
        XCTAssertEqual(self.finishedScanCount(), 1)
        withExtendedLifetime(cleanup) {}
    }

    func testTheScanWaitsForTheFirstMinuteAfterLaunch() {
        let cleanup = self.makeCleanup(processStartTime: Date().timeIntervalSince1970)
        cleanup.setMaxStoreTimes(general: self.limits.general, shortLived: self.limits.shortLived, gigabytesLimit: self.limits.gigabytes)

        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(self.finishedScanCount(), 0, "the scan started within the first minute")
        XCTAssertNil(self.record())
        withExtendedLifetime(cleanup) {}
    }
}
