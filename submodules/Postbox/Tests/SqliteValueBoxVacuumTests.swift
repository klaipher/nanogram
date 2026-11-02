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
