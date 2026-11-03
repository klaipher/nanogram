import Foundation
import XCTest
import SwiftSignalKit
import sqlcipher
@testable import Postbox

final class SqliteValueBoxConnectionTests: XCTestCase {
    private let binaryTable = ValueBoxTable(id: 2000, keyType: .binary, compactValuesOnCreation: true)
    private let int64Table = ValueBoxTable(id: 2001, keyType: .int64, compactValuesOnCreation: false)

    private let queue = Queue(name: "SqliteValueBoxConnectionTests")
    private let basePath = NSTemporaryDirectory() + "SqliteValueBoxConnectionTests-" + UUID().uuidString
    /// `SqliteValueBox.deinit` must run on its queue, so every box is closed in tearDown.
    private var openedBoxes: [SqliteValueBox] = []

    override func tearDown() {
        self.queue.sync {
            for box in self.openedBoxes {
                box.internalClose()
            }
            self.openedBoxes.removeAll()
        }
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func open(inMemory: Bool = false, isTemporary: Bool = true, removeDatabaseOnError: Bool = true, useCaches: Bool = true, cacheSizePages: Int? = nil) -> SqliteValueBox {
        var result: SqliteValueBox?
        self.queue.sync {
            result = SqliteValueBox(basePath: self.basePath, queue: self.queue, isTemporary: isTemporary, isReadOnly: false, useCaches: useCaches, removeDatabaseOnError: removeDatabaseOnError, encryptionParameters: nil, cacheSizePages: cacheSizePages, upgradeProgress: { _ in }, inMemory: inMemory)
            if let result {
                self.openedBoxes.append(result)
            }
        }
        guard let result else {
            XCTFail("could not open the value box")
            preconditionFailure()
        }
        return result
    }

    /// Rows are stored at keys 10..<count+10, so key 0 lies below every row in both the binary
    /// (big-endian bytes) and the int64 ordering.
    private static let rowKeyOffset = 10

    private func key(_ value: Int) -> ValueBoxKey {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: Int64(value))
        return key
    }

    private func fill(_ box: SqliteValueBox, table: ValueBoxTable, count: Int, valueSize: Int = 16) {
        self.queue.sync {
            box.begin()
            let buffer = WriteBuffer()
            for i in 0 ..< count {
                buffer.reset()
                var payload = [UInt8](repeating: UInt8(truncatingIfNeeded: i % 251), count: valueSize)
                buffer.write(&payload, offset: 0, length: payload.count)
                box.set(table, key: self.key(i + SqliteValueBoxConnectionTests.rowKeyOffset), value: buffer)
            }
            box.commit()
        }
    }

    private func fileSize(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private var databasePath: String {
        return self.basePath + "/db_sqlite"
    }

    // MARK: - LIMIT ? statements are not re-prepared (SQLITE_ENABLE_QPSG)

    func testRangeWithLimitDoesNotReprepare() {
        let box = self.open(inMemory: true)
        self.fill(box, table: self.binaryTable, count: 500)
        self.fill(box, table: self.int64Table, count: 500)

        self.queue.sync {
            box.begin()
            // Warm every statement once; preparing is not a re-prepare.
            for table in [self.binaryTable, self.int64Table] {
                let low = self.key(0)
                let high = self.key(1000)
                box.range(table, start: low, end: high, values: { _, _ in true }, limit: 1)
                box.range(table, start: high, end: low, values: { _, _ in true }, limit: 1)
                box.range(table, start: low, end: high, keys: { _ in true }, limit: 1)
                box.range(table, start: high, end: low, keys: { _ in true }, limit: 1)
            }
            let before = box.statementStatusTotal(SQLITE_STMTSTATUS_REPREPARE)
            var rows = 0
            for i in 0 ..< 200 {
                let limit = i % 2 == 0 ? 10 : 20
                for table in [self.binaryTable, self.int64Table] {
                    let low = self.key(i)
                    let high = self.key(1000)
                    box.range(table, start: low, end: high, values: { _, _ in rows += 1; return true }, limit: limit)
                    box.range(table, start: high, end: low, values: { _, _ in rows += 1; return true }, limit: limit)
                    box.range(table, start: low, end: high, keys: { _ in rows += 1; return true }, limit: limit)
                    box.range(table, start: high, end: low, keys: { _ in rows += 1; return true }, limit: limit)
                }
            }
            let reprepares = box.statementStatusTotal(SQLITE_STMTSTATUS_REPREPARE) - before
            box.commit()
            XCTAssertGreaterThan(rows, 0)
            XCTAssertEqual(reprepares, 0, "range(limit:) re-prepared its statement on \(reprepares) of 1600 calls")
        }
    }

    func testBenchmarkRangeWithLimit() {
        let box = self.open(inMemory: true)
        self.fill(box, table: self.binaryTable, count: 2000)
        self.queue.sync {
            box.begin()
            let iterations = 20000
            let before = box.statementStatusTotal(SQLITE_STMTSTATUS_REPREPARE)
            let start = CFAbsoluteTimeGetCurrent()
            var rows = 0
            for i in 0 ..< iterations {
                let first = i % 1900
                box.range(self.binaryTable, start: self.key(first), end: self.key(3000), values: { _, _ in rows += 1; return true }, limit: i % 2 == 0 ? 10 : 20)
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let reprepares = box.statementStatusTotal(SQLITE_STMTSTATUS_REPREPARE) - before
            box.commit()
            print("BENCH range(limit:) \(iterations) calls, \(rows) rows: \(String(format: "%.2f", elapsed / Double(iterations) * 1e6)) us/call, \(reprepares) re-prepares")
        }
    }

    // MARK: - BEGIN/COMMIT are prepared once per connection

    func testTransactionStatementsArePreparedOnce() {
        let box = self.open()
        self.queue.sync {
            box.begin()
            box.commit()
            let afterFirst = box.liveStatementSQL()
            XCTAssertTrue(afterFirst.contains("BEGIN IMMEDIATE"), "\(afterFirst)")
            XCTAssertTrue(afterFirst.contains("COMMIT"), "\(afterFirst)")
            for _ in 0 ..< 100 {
                box.begin()
                box.commit()
            }
            XCTAssertEqual(box.liveStatementSQL().count, afterFirst.count)
        }
        // Transactions still commit.
        self.fill(box, table: self.int64Table, count: 10)
        self.queue.sync {
            box.begin()
            XCTAssertEqual(box.count(self.int64Table), 10)
            box.commit()
        }
    }

    func testBenchmarkBeginCommit() {
        let box = self.open()
        self.fill(box, table: self.int64Table, count: 100)
        self.queue.sync {
            let iterations = 20000
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0 ..< iterations {
                box.begin()
                let _ = box.get(self.int64Table, key: self.key(i % 100 + SqliteValueBoxConnectionTests.rowKeyOffset))
                box.commit()
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            print("BENCH begin+get+commit \(iterations) transactions: \(String(format: "%.2f", elapsed / Double(iterations) * 1e6)) us/transaction")
        }
    }

    // MARK: - filteredRange: one query per call, stops at the accepted limit

    /// Stored keys strictly between the two bounds, in scan order, that `accept` takes.
    private func reference(count: Int, from start: Int, to end: Int, accept: (Int) -> Bool) -> [Int] {
        let rows = Array(SqliteValueBoxConnectionTests.rowKeyOffset ..< count + SqliteValueBoxConnectionTests.rowKeyOffset)
        if start < end {
            return rows.filter { $0 > start && $0 < end && accept($0) }
        } else {
            return rows.reversed().filter { $0 > end && $0 < start && accept($0) }
        }
    }

    func testFilteredRangeValuesRunsOneQueryAndMatchesAScan() {
        let box = self.open(inMemory: true)
        let count = 2000
        self.fill(box, table: self.binaryTable, count: count)
        self.fill(box, table: self.int64Table, count: count)

        self.queue.sync {
            box.begin()
            for table in [self.binaryTable, self.int64Table] {
                for (low, high) in [(0, 5000), (5000, 0), (300, 1700), (1700, 300)] {
                    let accept: (Int) -> Bool = { $0 % 7 == 0 }
                    let runsBefore = box.statementStatusTotal(SQLITE_STMTSTATUS_RUN)
                    var accepted: [Int] = []
                    box.filteredRange(table, start: self.key(low), end: self.key(high), values: { key, _ in
                        let value = Int(key.getInt64(0))
                        if accept(value) {
                            accepted.append(value)
                            return .accept
                        }
                        return .skip
                    }, limit: 25)
                    let runs = box.statementStatusTotal(SQLITE_STMTSTATUS_RUN) - runsBefore
                    let expected = Array(self.reference(count: count, from: low, to: high, accept: accept).prefix(25))
                    XCTAssertEqual(accepted, expected, "table \(table.id) \(low)->\(high)")
                    XCTAssertEqual(runs, 1, "table \(table.id) \(low)->\(high) ran \(runs) queries")
                }
            }
            box.commit()
        }
    }

    func testFilteredRangeValuesWithoutLimitAndWithStop() {
        let box = self.open(inMemory: true)
        let count = 300
        self.fill(box, table: self.binaryTable, count: count)

        self.queue.sync {
            box.begin()
            var all: [Int] = []
            box.filteredRange(self.binaryTable, start: self.key(0), end: self.key(count + 100), values: { key, _ in
                let value = Int(key.getInt64(0))
                if value % 2 == 0 {
                    all.append(value)
                    return .accept
                }
                return .skip
            }, limit: 0)
            XCTAssertEqual(all, self.reference(count: count, from: 0, to: count + 100, accept: { $0 % 2 == 0 }))

            var seen: [Int] = []
            box.filteredRange(self.binaryTable, start: self.key(0), end: self.key(count + 100), values: { key, _ in
                let value = Int(key.getInt64(0))
                seen.append(value)
                return value == 51 ? .stop : .skip
            }, limit: 10)
            XCTAssertEqual(seen, Array(10 ... 51))
            box.commit()
        }
    }

    func testFilteredRangeKeysStopsAtTheAcceptedLimit() {
        let box = self.open(inMemory: true)
        let count = 1000
        self.fill(box, table: self.binaryTable, count: count)

        self.queue.sync {
            box.begin()
            let accept: (Int) -> Bool = { $0 % 3 != 0 }
            let runsBefore = box.statementStatusTotal(SQLITE_STMTSTATUS_RUN)
            var accepted: [Int] = []
            box.filteredRange(self.binaryTable, start: self.key(0), end: self.key(count + 100), keys: { key in
                let value = Int(key.getInt64(0))
                if accept(value) {
                    accepted.append(value)
                    return .accept
                }
                return .skip
            }, limit: 10)
            let runs = box.statementStatusTotal(SQLITE_STMTSTATUS_RUN) - runsBefore
            XCTAssertEqual(accepted, Array(self.reference(count: count, from: 0, to: count + 100, accept: accept).prefix(10)))
            XCTAssertEqual(runs, 1)
            box.commit()
        }
    }

    // MARK: - Checkpoint policy

    func testWalPolicyIsSetOnEveryConnection() {
        let box = self.open()
        self.queue.sync {
            XCTAssertEqual(box.pragmaValue("journal_size_limit"), String(SqliteValueBox.walJournalSizeLimit))
            XCTAssertEqual(box.pragmaValue("checkpoint_fullfsync"), "1")
            XCTAssertEqual(box.pragmaValue("synchronous"), "1")
        }
    }

    // releaseMemory runs when the app enters the background; a checkpoint there would hold the
    // database locks and sync right before suspension (0xdead10cc), so it must not checkpoint.
    func testReleaseMemoryDoesNotCheckpoint() {
        let box = self.open()
        // ~200 frames: below the autocheckpoint threshold, so the pages stay in the WAL.
        self.fill(box, table: self.int64Table, count: 200, valueSize: 4000)
        let before = self.fileSize(self.databasePath)
        self.queue.sync {
            box.releaseMemory()
        }
        XCTAssertEqual(self.fileSize(self.databasePath), before)
    }

    func testAutocheckpointRunsPastTheThreshold() {
        let box = self.open()
        // ~1500 frames in one commit: past the 1000-frame threshold.
        self.fill(box, table: self.int64Table, count: 1500, valueSize: 4000)
        XCTAssertGreaterThan(self.fileSize(self.databasePath), 5_000_000)
    }

    func testWalShrinksToTheJournalSizeLimitAfterABurst() {
        let box = self.open()
        // ~30 MB in one transaction; the autocheckpoint at its commit backfills it.
        self.fill(box, table: self.int64Table, count: 7500, valueSize: 4000)
        XCTAssertGreaterThan(self.fileSize(self.databasePath + "-wal"), 20_000_000)
        // The next write restarts the WAL and truncates it to the limit.
        self.fill(box, table: self.binaryTable, count: 1)
        let walSize = self.fileSize(self.databasePath + "-wal")
        XCTAssertLessThanOrEqual(walSize, SqliteValueBox.walJournalSizeLimit, "wal is \(walSize) bytes")
    }

    // MARK: - Page cache size

    func testCacheSizeIsOnlyChangedWhenAsked() {
        let defaultBox = self.open(useCaches: true)
        let extensionBox = self.open(useCaches: false)
        let shareExtensionBox = self.open(useCaches: false, cacheSizePages: 256)
        self.queue.sync {
            XCTAssertEqual(defaultBox.pragmaValue("cache_size"), "-2000")
            XCTAssertEqual(extensionBox.pragmaValue("cache_size"), "32")
            XCTAssertEqual(shareExtensionBox.pragmaValue("cache_size"), "256")
        }
    }

    // MARK: - FTS5 index corruption

    func testOnlyCorruptVirtualTableIsRebuildable() {
        let corruptVirtualTable = SQLITE_CORRUPT | (1 << 8)
        XCTAssertTrue(isRebuildableFullTextCorruption(resultCode: SQLITE_CORRUPT, extendedResultCode: corruptVirtualTable))
        XCTAssertFalse(isRebuildableFullTextCorruption(resultCode: SQLITE_CORRUPT, extendedResultCode: SQLITE_CORRUPT))
        XCTAssertFalse(isRebuildableFullTextCorruption(resultCode: SQLITE_CORRUPT, extendedResultCode: SQLITE_CORRUPT | (2 << 8)))
        XCTAssertFalse(isRebuildableFullTextCorruption(resultCode: SQLITE_CORRUPT, extendedResultCode: SQLITE_CORRUPT | (3 << 8)))
        XCTAssertFalse(isRebuildableFullTextCorruption(resultCode: SQLITE_IOERR, extendedResultCode: corruptVirtualTable))
        XCTAssertFalse(isRebuildableFullTextCorruption(resultCode: SQLITE_BUSY, extendedResultCode: SQLITE_BUSY))
    }

    private let fullTextTable = ValueBoxFullTextTable(id: 7)

    private func makeCorruptFullTextIndex(_ box: SqliteValueBox, count: Int) {
        self.queue.sync {
            box.begin()
            for i in 0 ..< count {
                box.fullTextSet(self.fullTextTable, collectionId: "c\(i % 50)", itemId: "i\(i)", contents: "hello world message number \(i)", tags: "t")
            }
            box.commit()
        }
        guard let damage = Database(self.databasePath, readOnly: false) else {
            XCTFail("could not open a second connection")
            return
        }
        XCTAssertTrue(damage.execute("UPDATE ft7_data SET block = zeroblob(length(block)) WHERE id > 10"))
        XCTAssertFalse(damage.execute("INSERT INTO ft7(ft7) VALUES('integrity-check')"))
    }

    private func matchCount(_ box: SqliteValueBox, query: String) -> Int {
        var result = 0
        self.queue.sync {
            box.begin()
            box.fullTextMatch(self.fullTextTable, collectionId: nil, query: query, tags: nil, values: { _, _ in
                result += 1
                return true
            })
            box.commit()
        }
        return result
    }

    func testOwnerRebuildsACorruptFullTextIndexInsteadOfDeletingTheDatabase() {
        let owner = self.open(isTemporary: false, removeDatabaseOnError: true, useCaches: false)
        self.fill(owner, table: self.int64Table, count: 10)
        self.makeCorruptFullTextIndex(owner, count: 3000)

        XCTAssertEqual(self.matchCount(owner, query: "hello"), 3000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.databasePath))
        self.queue.sync {
            owner.begin()
            XCTAssertEqual(owner.count(self.int64Table), 10)
            owner.fullTextSet(self.fullTextTable, collectionId: "c", itemId: "new", contents: "fresh words", tags: "t")
            owner.commit()
        }
        XCTAssertEqual(self.matchCount(owner, query: "fresh"), 1)
        let check = Database(self.databasePath, readOnly: false)
        XCTAssertEqual(check?.execute("INSERT INTO ft7(ft7) VALUES('integrity-check')"), true)
    }

    func testNonOwnerLeavesACorruptFullTextIndexAlone() {
        let owner = self.open(isTemporary: false, removeDatabaseOnError: true, useCaches: false)
        self.makeCorruptFullTextIndex(owner, count: 3000)

        let extensionBox = self.open(isTemporary: true, removeDatabaseOnError: true, useCaches: false)
        XCTAssertEqual(self.matchCount(extensionBox, query: "hello"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.databasePath))
        let check = Database(self.databasePath, readOnly: false)
        XCTAssertEqual(check?.execute("INSERT INTO ft7(ft7) VALUES('integrity-check')"), false, "a non-owner must not rewrite the index")
    }

    // MARK: - exists() reads no value

    private let withoutRowIdTable = ValueBoxTable(id: 2002, keyType: .binary, compactValuesOnCreation: true)
    private let rowIdBinaryTable = ValueBoxTable(id: 2003, keyType: .binary, compactValuesOnCreation: false)

    private func queryPlan(_ sql: String) -> String {
        guard let database = Database(self.databasePath, readOnly: true) else {
            XCTFail("could not open a second connection")
            return ""
        }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database.handle, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil), SQLITE_OK)
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 3) {
                details.append(String(cString: text))
            }
        }
        sqlite3_finalize(statement)
        return details.joined(separator: "; ")
    }

    func testExistsIsCorrectOnEveryTableKindAndReadsNoValue() {
        let box = self.open(isTemporary: false)
        let tables = [self.int64Table, self.rowIdBinaryTable, self.withoutRowIdTable]
        for table in tables {
            self.fill(box, table: table, count: 50, valueSize: 3000)
        }
        self.queue.sync {
            for table in tables {
                XCTAssertTrue(box.exists(table, key: self.key(SqliteValueBoxConnectionTests.rowKeyOffset)), "t\(table.id)")
                XCTAssertTrue(box.exists(table, key: self.key(SqliteValueBoxConnectionTests.rowKeyOffset + 49)), "t\(table.id)")
                XCTAssertFalse(box.exists(table, key: self.key(0)), "t\(table.id)")
                XCTAssertFalse(box.exists(table, key: self.key(1000)), "t\(table.id)")
            }
            XCTAssertFalse(box.exists(ValueBoxTable(id: 2999, keyType: .int64, compactValuesOnCreation: false), key: self.key(10)))
            let statements = box.liveStatementSQL()
            for table in tables {
                XCTAssertTrue(statements.contains("SELECT 1 FROM t\(table.id) WHERE key=?"), "t\(table.id): \(statements)")
                XCTAssertFalse(statements.contains("SELECT value FROM t\(table.id) WHERE key=?"), "t\(table.id): \(statements)")
            }
        }
        XCTAssertTrue(self.queryPlan("SELECT 1 FROM t\(self.rowIdBinaryTable.id) WHERE key=?").contains("COVERING INDEX"))
        XCTAssertTrue(self.queryPlan("SELECT 1 FROM t\(self.withoutRowIdTable.id) WHERE key=?").contains("PRIMARY KEY"))
        XCTAssertTrue(self.queryPlan("SELECT 1 FROM t\(self.int64Table.id) WHERE key=?").contains("PRIMARY KEY"))
    }
}
