import Foundation
import XCTest
import SwiftSignalKit
import sqlcipher
@testable import Postbox

/// Debug Settings' "Optimize Database" crashed the app (a `precondition`) whenever VACUUM
/// failed: the notification extension holding the database, a full disk or an I/O error.
/// VACUUM now logs and returns false, and background maintenance runs it only when free pages
/// are at least a quarter of the file, at most once a week.
final class SqliteValueBoxVacuumTests: XCTestCase {
    private let table = ValueBoxTable(id: 1001, keyType: .int64, compactValuesOnCreation: true)

    private var queue: Queue!
    private var basePath: String!
    private var valueBox: SqliteValueBox!

    override func setUp() {
        super.setUp()
        self.queue = Queue(name: "SqliteValueBoxVacuumTests")
        self.basePath = NSTemporaryDirectory() + "SqliteValueBoxVacuumTests-" + UUID().uuidString
        self.queue.sync {
            self.valueBox = SqliteValueBox(basePath: self.basePath, queue: self.queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: false)
        }
        XCTAssertNotNil(self.valueBox)
    }

    override func tearDown() {
        self.queue.sync {
            self.valueBox?.internalClose()
            self.valueBox = nil
        }
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func onQueue(_ f: () throws -> Void) throws {
        var thrown: Error?
        self.queue.sync {
            do {
                try f()
            } catch let error {
                thrown = error
            }
        }
        if let thrown {
            throw thrown
        }
    }

    private func key(_ value: Int64) -> ValueBoxKey {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: value)
        return key
    }

    private func fill(count: Int, removeEvery: Int?) {
        self.valueBox.begin()
        let buffer = WriteBuffer()
        for i in 0 ..< count {
            buffer.reset()
            var payload = [UInt8](repeating: UInt8(i % 251), count: 1024)
            buffer.write(&payload, offset: 0, length: payload.count)
            self.valueBox.set(self.table, key: self.key(Int64(i)), value: buffer)
        }
        self.valueBox.commit()
        if let removeEvery = removeEvery {
            self.valueBox.begin()
            for i in 0 ..< count where i % removeEvery != 0 {
                self.valueBox.remove(self.table, key: self.key(Int64(i)), secure: false)
            }
            self.valueBox.commit()
        }
    }

    private func remainingValues() -> [Int64: UInt8] {
        var result: [Int64: UInt8] = [:]
        self.valueBox.scanInt64(self.table, values: { key, value in
            var first: UInt8 = 0
            value.read(&first, offset: 0, length: 1)
            result[key] = first
            return true
        })
        return result
    }

    func testFragmentedDatabaseIsVacuumedAndKeepsItsData() throws {
        try self.onQueue {
            self.fill(count: 4000, removeEvery: 4)
            let expected = self.remainingValues()
            XCTAssertEqual(expected.count, 1000)
            let before = try XCTUnwrap(self.valueBox.pageStats())
            XCTAssertGreaterThan(before.freeFraction, 0.25)

            let result = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: nil)
            guard case let .vacuumed(statsBefore, statsAfter) = result else {
                XCTFail("expected a VACUUM, got \(result)")
                return
            }
            XCTAssertEqual(statsBefore, before)
            let after = try XCTUnwrap(statsAfter)
            XCTAssertEqual(after.freePageCount, 0)
            XCTAssertLessThan(after.pageCount, before.pageCount / 2)
            XCTAssertEqual(self.remainingValues(), expected)
        }
    }

    func testCompactDatabaseIsLeftAlone() throws {
        try self.onQueue {
            self.fill(count: 2000, removeEvery: nil)
            let before = try XCTUnwrap(self.valueBox.pageStats())
            guard case .notFragmented = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: nil) else {
                XCTFail("a database without free pages must not be rewritten")
                return
            }
            XCTAssertEqual(self.valueBox.pageStats(), before)
        }
    }

    func testVacuumIsSkippedWithoutRoomForTheCopy() throws {
        try self.onQueue {
            self.fill(count: 4000, removeEvery: 4)
            let before = try XCTUnwrap(self.valueBox.pageStats())
            guard case .insufficientDiskSpace = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: 4096) else {
                XCTFail("expected a skip")
                return
            }
            XCTAssertEqual(self.valueBox.pageStats(), before)
        }
    }

    // Another connection (in the app, the notification extension) holds a write lock: VACUUM
    // waits out the busy timeout and fails instead of crashing; the data is untouched.
    func testBusyDatabaseFailsWithoutCrashing() throws {
        self.queue.sync {
            self.fill(count: 1000, removeEvery: 2)
        }
        let dbPath = self.basePath + "/db_sqlite"
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &other), SQLITE_OK)
        defer {
            sqlite3_close(other)
        }
        XCTAssertEqual(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        try self.onQueue {
            let before = try XCTUnwrap(self.valueBox.pageStats())
            XCTAssertFalse(self.valueBox.vacuum())
            guard case .failed = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: nil) else {
                XCTFail("expected a failure")
                return
            }
            XCTAssertEqual(self.valueBox.pageStats(), before)
            XCTAssertEqual(self.remainingValues().count, 500)
        }
        XCTAssertEqual(sqlite3_exec(other, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        self.queue.sync {
            XCTAssertTrue(self.valueBox.vacuum(), "works again once the other connection lets go")
        }
    }

    func testVacuumWaitsWhenTheUserIsBack() throws {
        try self.onQueue {
            self.fill(count: 4000, removeEvery: 4)
            let before = try XCTUnwrap(self.valueBox.pageStats())
            var askedOnQueue: Bool?
            let result = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: nil, maxLiveBytes: nil, shouldProceed: {
                askedOnQueue = self.queue.isCurrent()
                return false
            })
            XCTAssertEqual(result, .deferred)
            XCTAssertEqual(askedOnQueue, true)
            XCTAssertEqual(self.valueBox.pageStats(), before)
        }
    }

    // Background time is up: another thread interrupts the VACUUM. Whether it lands before the VACUUM finishes
    // or not, nothing is lost and the box keeps working.
    func testInterruptDuringVacuumKeepsTheData() throws {
        try self.onQueue {
            self.fill(count: 20000, removeEvery: 4)
        }
        var expected: [Int64: UInt8] = [:]
        self.queue.sync {
            expected = self.remainingValues()
        }
        let gate = self.valueBox.interruptGate
        let stop = Atomic<Bool>(value: false)
        let interrupter = Thread {
            while !stop.with({ $0 }) {
                gate.interrupt()
                usleep(200)
            }
        }
        interrupter.start()
        var succeeded = false
        self.queue.sync {
            succeeded = self.valueBox.vacuum()
        }
        let _ = stop.swap(true)
        self.queue.sync {
            XCTAssertEqual(self.remainingValues(), expected)
            // Not stuck in a half-done state: the next VACUUM works.
            XCTAssertTrue(self.valueBox.vacuum(), "vacuum works again (first one succeeded: \(succeeded))")
        }
    }

    func testInterruptOutsideMaintenanceDoesNothing() throws {
        let gate = self.valueBox.interruptGate
        gate.interrupt()
        try self.onQueue {
            self.fill(count: 100, removeEvery: nil)
            XCTAssertEqual(self.remainingValues().count, 100)
        }
    }

    func testCompactDatabaseDoesNotAskWhetherToProceed() throws {
        try self.onQueue {
            self.fill(count: 2000, removeEvery: nil)
            var asked = false
            let result = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: nil, maxLiveBytes: nil, shouldProceed: {
                asked = true
                return true
            })
            guard case .notFragmented = result else {
                XCTFail("expected no VACUUM, got \(result)")
                return
            }
            XCTAssertFalse(asked)
        }
    }

    func testDatabaseAboveTheSizeCapIsLeftAlone() throws {
        try self.onQueue {
            self.fill(count: 4000, removeEvery: 4)
            let before = try XCTUnwrap(self.valueBox.pageStats())
            let liveBytes = (before.pageCount - before.freePageCount) * before.pageSize
            let result = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: nil, maxLiveBytes: liveBytes - 1, shouldProceed: { true })
            XCTAssertEqual(result, .tooLarge(liveBytes: liveBytes, limit: liveBytes - 1))
            XCTAssertEqual(self.valueBox.pageStats(), before)
            guard case .vacuumed = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: nil, maxLiveBytes: liveBytes, shouldProceed: { true }) else {
                XCTFail("a database at the cap is vacuumed")
                return
            }
        }
    }

    func testEncryptedFragmentedDatabaseIsVacuumedAndReopensWithItsKey() throws {
        let encryptedPath = NSTemporaryDirectory() + "SqliteValueBoxVacuumTests-encrypted-" + UUID().uuidString
        defer {
            let _ = try? FileManager.default.removeItem(atPath: encryptedPath)
        }
        let parameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data((0 ..< 32).map { UInt8($0) }))), salt: try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data((0 ..< 16).map { UInt8(100 + $0) }))))
        let open: () -> SqliteValueBox? = {
            return SqliteValueBox(basePath: encryptedPath, queue: self.queue, isTemporary: false, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, encryptionParameters: parameters, upgradeProgress: { _ in }, inMemory: false)
        }
        try self.onQueue {
            self.valueBox.internalClose()
            self.valueBox = try XCTUnwrap(open())
            self.fill(count: 4000, removeEvery: 4)
            let expected = self.remainingValues()
            XCTAssertEqual(expected.count, 1000)
            let result = self.valueBox.vacuumIfFragmented(minFreeFraction: 0.25, availableDiskSpace: nil, maxLiveBytes: nil, shouldProceed: { true })
            guard case let .vacuumed(before, statsAfter) = result else {
                XCTFail("expected a VACUUM, got \(result)")
                return
            }
            let after = try XCTUnwrap(statsAfter)
            XCTAssertEqual(after.freePageCount, 0)
            XCTAssertLessThan(after.pageCount, before.pageCount / 2)
            self.valueBox.internalClose()

            var plain: OpaquePointer?
            XCTAssertEqual(sqlite3_open(encryptedPath + "/db_sqlite", &plain), SQLITE_OK)
            XCTAssertNotEqual(sqlite3_exec(plain, "SELECT count(*) FROM sqlite_master", nil, nil, nil), SQLITE_OK, "still encrypted after VACUUM")
            sqlite3_close(plain)

            self.valueBox = try XCTUnwrap(open())
            XCTAssertEqual(self.remainingValues(), expected)
        }
    }

    func testOnlyAFinishedCheckWaitsAWeek() {
        let stats = SqliteValueBox.PageStats(pageCount: 10, freePageCount: 5, pageSize: 4096)
        XCTAssertTrue(PostboxStorageOptimizationSchedule.recordsRun(.vacuumed(before: stats, after: nil)))
        XCTAssertTrue(PostboxStorageOptimizationSchedule.recordsRun(.notFragmented(stats)))
        XCTAssertFalse(PostboxStorageOptimizationSchedule.recordsRun(.deferred), "the user came back: try again at the next run")
        XCTAssertFalse(PostboxStorageOptimizationSchedule.recordsRun(.tooLarge(liveBytes: 2, limit: 1)))
        XCTAssertFalse(PostboxStorageOptimizationSchedule.recordsRun(.insufficientDiskSpace(needed: 2, available: 1)))
        XCTAssertFalse(PostboxStorageOptimizationSchedule.recordsRun(.failed))
    }

    func testFailureDescriptions() {
        XCTAssertTrue(SqliteValueBox.describeVacuumFailure(SQLITE_BUSY).hasPrefix("database busy"))
        XCTAssertTrue(SqliteValueBox.describeVacuumFailure(SQLITE_FULL).hasPrefix("disk full"))
        XCTAssertTrue(SqliteValueBox.describeVacuumFailure(SQLITE_IOERR | (3 << 8)).hasPrefix("I/O error"))
        XCTAssertTrue(SqliteValueBox.describeVacuumFailure(SQLITE_READONLY).hasPrefix("read-only"))
    }

    func testScheduleRunsAtMostOncePerInterval() {
        let week = PostboxStorageOptimizationSchedule.defaultMinInterval
        XCTAssertEqual(week, 7 * 24 * 60 * 60)
        XCTAssertEqual(PostboxStorageOptimizationSchedule.defaultMinFreeFraction, 0.25)
        XCTAssertTrue(PostboxStorageOptimizationSchedule.isDue(lastRun: nil, now: 1000, minInterval: week))
        XCTAssertFalse(PostboxStorageOptimizationSchedule.isDue(lastRun: 1000, now: 1000 + week - 1, minInterval: week))
        XCTAssertTrue(PostboxStorageOptimizationSchedule.isDue(lastRun: 1000, now: 1000 + week, minInterval: week))
        XCTAssertTrue(PostboxStorageOptimizationSchedule.isDue(lastRun: 1000 + week, now: 1000, minInterval: week), "a clock moved backwards")

        let marker = self.basePath + "/marker"
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
        XCTAssertNil(PostboxStorageOptimizationSchedule.lastRun(markerPath: marker))
        PostboxStorageOptimizationSchedule.setLastRun(markerPath: marker, timestamp: 12345.5)
        XCTAssertEqual(PostboxStorageOptimizationSchedule.lastRun(markerPath: marker), 12345.5)
    }
}
