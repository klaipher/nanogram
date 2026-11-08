import Foundation
import XCTest
import SwiftSignalKit
import DiskWriteAccounting
import sqlcipher
@testable import Postbox

/// Pages a database writes to its WAL on commit, and copies into the database file on a checkpoint, are counted per
/// database (DiskWriteAccounting `sqlite.wal.<db>` / `sqlite.checkpoint.<db>`).
final class SqliteValueBoxWriteAccountingTests: XCTestCase {
    private let table = ValueBoxTable(id: 1002, keyType: .int64, compactValuesOnCreation: true)

    func testCommittedPagesAreCountedPerDatabase() {
        let queue = Queue(name: "SqliteValueBoxWriteAccountingTests")
        let basePath = NSTemporaryDirectory() + "SqliteValueBoxWriteAccountingTests-" + UUID().uuidString + "/postbox/db"
        defer {
            let _ = try? FileManager.default.removeItem(atPath: basePath)
        }
        let category = DiskWriteCategory.sqliteWal(database: "postbox/db")
        let before = DiskWriteAccounting.shared.bytesWritten(category)
        var walBytes: Int64 = 0
        queue.sync {
            guard let valueBox = SqliteValueBox(basePath: basePath, queue: queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: false) else {
                XCTFail("could not open the database")
                return
            }
            let afterOpen = DiskWriteAccounting.shared.bytesWritten(category)
            for i in 0 ..< 10 {
                valueBox.begin()
                let key = ValueBoxKey(length: 8)
                key.setInt64(0, value: Int64(i))
                valueBox.set(self.table, key: key, value: MemoryBuffer(data: Data(repeating: UInt8(i), count: 3000)))
                valueBox.commit()
            }
            walBytes = DiskWriteAccounting.shared.bytesWritten(category) - afterOpen
            valueBox.internalClose()
        }
        XCTAssertGreaterThan(DiskWriteAccounting.shared.bytesWritten(category), before)
        // Ten commits of a 3 KB row each write at least one page each (4 KB pages).
        XCTAssertGreaterThanOrEqual(walBytes, 10 * 4096)
    }

    func testTheFramesOfTheLastCommitAreTakenOnce() {
        let queue = Queue(name: "SqliteValueBoxWriteAccountingTests.lastCommit")
        let basePath = NSTemporaryDirectory() + "SqliteValueBoxWriteAccountingTests-" + UUID().uuidString + "/postbox/db"
        defer {
            let _ = try? FileManager.default.removeItem(atPath: basePath)
        }
        queue.sync {
            guard let valueBox = SqliteValueBox(basePath: basePath, queue: queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: false) else {
                XCTFail("could not open the database")
                return
            }
            let _ = valueBox.takeLastCommitAppendedFrames()
            valueBox.begin()
            let key = ValueBoxKey(length: 8)
            key.setInt64(0, value: 1)
            valueBox.set(self.table, key: key, value: MemoryBuffer(data: Data(repeating: 1, count: 3000)))
            valueBox.commit()
            XCTAssertGreaterThanOrEqual(valueBox.takeLastCommitAppendedFrames(), 1)
            XCTAssertEqual(valueBox.takeLastCommitAppendedFrames(), 0, "taken once")

            valueBox.begin()
            let _ = valueBox.get(self.table, key: key)
            valueBox.commit()
            XCTAssertEqual(valueBox.takeLastCommitAppendedFrames(), 0, "a read-only transaction appends nothing")
            valueBox.internalClose()
        }
    }

    private func commitRows(_ valueBox: SqliteValueBox, from start: Int, count: Int) {
        for i in start ..< start + count {
            valueBox.begin()
            let key = ValueBoxKey(length: 8)
            key.setInt64(0, value: Int64(i))
            valueBox.set(self.table, key: key, value: MemoryBuffer(data: Data(repeating: UInt8(i & 0xff), count: 3000)))
            valueBox.commit()
        }
    }

    /// `sqlite3_wal_checkpoint_v2` reports the WAL's total backfilled frames, not the frames this checkpoint copied.
    /// While another process reads (an extension), the WAL cannot restart, every commit past the autocheckpoint
    /// threshold runs a checkpoint, and each one reported the same backfilled frames again: phantom writes of
    /// megabytes per commit. A checkpoint can never copy more pages than commits wrote to the WAL.
    func testCheckpointsWhileAReaderPinsTheWalCountEachCopiedPageOnce() {
        let queue = Queue(name: "SqliteValueBoxWriteAccountingTests")
        let directory = NSTemporaryDirectory() + "SqliteWalPinned-" + UUID().uuidString
        let basePath = directory + "/db"
        defer {
            let _ = try? FileManager.default.removeItem(atPath: directory)
        }
        let name = DiskWriteCategory.databaseName(path: basePath)
        let walCategory = DiskWriteCategory.sqliteWal(database: name)
        let checkpointCategory = DiskWriteCategory.sqliteCheckpoint(database: name)
        queue.sync {
            guard let valueBox = SqliteValueBox(basePath: basePath, queue: queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: false) else {
                XCTFail("could not open the database")
                return
            }
            self.commitRows(valueBox, from: 0, count: 100)

            // Another connection (an extension) holds a read transaction: the WAL can be backfilled only up to its
            // snapshot and cannot restart.
            var reader: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(basePath + "/db_sqlite", &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(reader, "BEGIN DEFERRED; SELECT count(*) FROM sqlite_master;", nil, nil, nil), SQLITE_OK)

            self.commitRows(valueBox, from: 100, count: 1200)

            let walBytes = DiskWriteAccounting.shared.bytesWritten(walCategory)
            let checkpointBytes = DiskWriteAccounting.shared.bytesWritten(checkpointCategory)
            XCTAssertGreaterThan(checkpointBytes, 0, "the autocheckpoint ran")
            XCTAssertLessThanOrEqual(checkpointBytes, walBytes, "checkpoints copied more pages than were ever written to the WAL")

            sqlite3_exec(reader, "COMMIT", nil, nil, nil)
            sqlite3_close(reader)
            valueBox.internalClose()
        }
    }

    /// The idle checkpoint (`checkpoint()`, run when the database goes quiet) copies pages into the database file
    /// too; it is counted like the commit-time one.
    func testTheIdleCheckpointIsCounted() {
        let queue = Queue(name: "SqliteValueBoxWriteAccountingTests")
        let directory = NSTemporaryDirectory() + "SqliteWalIdle-" + UUID().uuidString
        let basePath = directory + "/db"
        defer {
            let _ = try? FileManager.default.removeItem(atPath: directory)
        }
        let name = DiskWriteCategory.databaseName(path: basePath)
        let checkpointCategory = DiskWriteCategory.sqliteCheckpoint(database: name)
        queue.sync {
            guard let valueBox = SqliteValueBox(basePath: basePath, queue: queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: false) else {
                XCTFail("could not open the database")
                return
            }
            // Well under the autocheckpoint threshold: only the idle checkpoint copies these pages.
            self.commitRows(valueBox, from: 0, count: 10)
            XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten(checkpointCategory), 0)
            valueBox.checkpoint()
            XCTAssertGreaterThanOrEqual(DiskWriteAccounting.shared.bytesWritten(checkpointCategory), 10 * 4096)
            valueBox.internalClose()
        }
    }

    private func writeFakeWal(path: String, pages: [UInt32], pageSize: Int = 4096) {
        var data = Data(count: 32)
        for page in pages {
            var header = Data(count: 24)
            header[0] = UInt8((page >> 24) & 0xff)
            header[1] = UInt8((page >> 16) & 0xff)
            header[2] = UInt8((page >> 8) & 0xff)
            header[3] = UInt8(page & 0xff)
            data.append(header)
            data.append(Data(count: pageSize))
        }
        FileManager.default.createFile(atPath: path, contents: data)
    }

    /// A checkpoint writes the newest copy of each page once, however many frames carry that page.
    func testCheckpointCountsDistinctPagesNotFrames() {
        let directory = NSTemporaryDirectory() + "SqliteWalDistinct-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { let _ = try? FileManager.default.removeItem(atPath: directory) }
        let databasePath = directory + "/db_sqlite"
        self.writeFakeWal(path: databasePath + "-wal", pages: [1, 2, 1, 1, 3, 2, 1, 4])
        let accounting = SqliteWalWriteAccounting(databasePath: databasePath, handle: nil)
        let category = accounting.checkpointCategory
        let before = DiskWriteAccounting.shared.bytesWritten(category)
        accounting.checkpointed(backfilledFrames: 8)
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten(category) - before, Int64(4 * 4096))
    }

    /// Only the frames backfilled since the previous checkpoint are looked at; pages already copied are not counted
    /// again unless a newer frame carries them.
    func testSecondCheckpointCountsOnlyNewFrames() {
        let directory = NSTemporaryDirectory() + "SqliteWalDelta-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { let _ = try? FileManager.default.removeItem(atPath: directory) }
        let databasePath = directory + "/db_sqlite"
        self.writeFakeWal(path: databasePath + "-wal", pages: [1, 2, 3, 3, 3, 9, 9])
        let accounting = SqliteWalWriteAccounting(databasePath: databasePath, handle: nil)
        let category = accounting.checkpointCategory
        let before = DiskWriteAccounting.shared.bytesWritten(category)
        accounting.checkpointed(backfilledFrames: 3)
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten(category) - before, Int64(3 * 4096))
        accounting.checkpointed(backfilledFrames: 7)
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten(category) - before, Int64(5 * 4096))
        accounting.checkpointed(backfilledFrames: 7)
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten(category) - before, Int64(5 * 4096), "nothing new to copy")
    }

    func testUnreadableWalFallsBackToTheFrameCount() {
        let directory = NSTemporaryDirectory() + "SqliteWalMissing-" + UUID().uuidString
        let accounting = SqliteWalWriteAccounting(databasePath: directory + "/db_sqlite", handle: nil)
        let category = accounting.checkpointCategory
        let before = DiskWriteAccounting.shared.bytesWritten(category)
        accounting.checkpointed(backfilledFrames: 5)
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten(category) - before, Int64(5 * 4096))
    }

    /// Rewriting the same row over and over fills the WAL with copies of a few pages; the checkpoint writes those
    /// pages once, not once per frame.
    func testCheckpointOfARewrittenRowCountsFewPages() {
        let queue = Queue(name: "SqliteValueBoxWriteAccountingTests.rewrite")
        let directory = NSTemporaryDirectory() + "SqliteWalRewrite-" + UUID().uuidString
        let basePath = directory + "/db"
        defer { let _ = try? FileManager.default.removeItem(atPath: directory) }
        let checkpointCategory = DiskWriteCategory.sqliteCheckpoint(database: DiskWriteCategory.databaseName(path: basePath))
        queue.sync {
            guard let valueBox = SqliteValueBox(basePath: basePath, queue: queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: false) else {
                XCTFail("could not open the database")
                return
            }
            // Past the autocheckpoint threshold, whatever it is set to.
            for i in 0 ..< Int(SqliteValueBox.walAutocheckpointFrames) + 100 {
                valueBox.begin()
                let key = ValueBoxKey(length: 8)
                key.setInt64(0, value: 1)
                valueBox.set(self.table, key: key, value: MemoryBuffer(data: Data(repeating: UInt8(i & 0xff), count: 100)))
                valueBox.commit()
            }
            let bytes = DiskWriteAccounting.shared.bytesWritten(checkpointCategory)
            XCTAssertGreaterThan(bytes, 0, "the autocheckpoint ran")
            XCTAssertLessThanOrEqual(bytes, 20 * 4096, "a full WAL of a few distinct pages")
            valueBox.internalClose()
        }
    }

    func testLargeCommitsAndCheckpointsGetANotice() {
        let basePath = NSTemporaryDirectory() + "SqliteValueBoxWriteAccountingTests-" + UUID().uuidString
        let accounting = SqliteWalWriteAccounting(databasePath: basePath + "/postbox/db/db_sqlite", handle: nil, largeWriteBytes: 40000)
        XCTAssertEqual(accounting.frameSize, 24 + 4096)
        // The first commit finds frames that were there before the connection: said so.
        let first = accounting.committed(walFrames: 20)
        XCTAssertTrue(first?.contains("first commit") == true, first ?? "")
        // Small growth: no notice. Growth past the threshold: a notice with the size.
        XCTAssertNil(accounting.committed(walFrames: 25))
        let large = accounting.committed(walFrames: 45)
        XCTAssertTrue(large?.contains("the WAL grew by 20 frames") == true, large ?? "")
        // No WAL file to read: the frame count is the upper bound for the checkpoint.
        XCTAssertNil(accounting.checkpointed(backfilledFrames: 5))
        let checkpoint = accounting.checkpointed(backfilledFrames: 45)
        XCTAssertTrue(checkpoint?.contains("a checkpoint copied 40 pages") == true, checkpoint ?? "")
    }

    /// The first commit of a connection finds the WAL another process left (the previous process, an extension): those
    /// frames are not this transaction's, so the per-transaction attribution must not get them.
    func testInheritedFramesAreNotAttributedToTheFirstTransaction() {
        let accounting = SqliteWalWriteAccounting(databasePath: NSTemporaryDirectory() + "y/postbox/db/db_sqlite", handle: nil, largeWriteBytes: 40000)
        accounting.committed(walFrames: 5000)
        XCTAssertEqual(accounting.takeLastCommitAppendedFrames(), 0)
        accounting.committed(walFrames: 5030)
        XCTAssertEqual(accounting.takeLastCommitAppendedFrames(), 30)
    }

    func testAFirstCommitWithAnEmptyWalGetsNoNotice() {
        let accounting = SqliteWalWriteAccounting(databasePath: NSTemporaryDirectory() + "x/postbox/db/db_sqlite", handle: nil, largeWriteBytes: 40000)
        XCTAssertNil(accounting.committed(walFrames: 2))
    }
}
