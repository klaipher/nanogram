import Foundation
import XCTest
import SwiftSignalKit
import sqlcipher
@testable import Postbox

/// `StorageBox` is MediaBox's index of cached files (`storage`, `cache-storage`). Losing it costs a
/// re-index, never data, so a database that cannot be opened, is locked by another process or
/// has an unusable table must never crash the app. The box then keeps working (in memory when
/// the file cannot be opened) and the file is retried on the next open or the next write.
///
/// Device crash this pins (TestFlight 202611020509, EXC_BREAKPOINT): a new StorageBox whose
/// `BEGIN IMMEDIATE` and `CREATE TABLE t21` failed without a trap, so the metadata write in
/// `performUpdatesIfNeeded` (StorageBox.swift:328) reached the `preconditionFailure` in
/// `SqliteValueBox.insertOrReplaceStatement` (SqliteValueBox.swift:1510).
final class StorageBoxUnavailableDatabaseTests: XCTestCase {
    private let contentType: UInt8 = 2
    private var basePath = ""
    private var savedBusyTimeout: Int32 = 0

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "StorageBoxUnavailableDatabaseTests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
        // Every wait for another connection's lock ends quickly, so "locked" fails fast.
        self.savedBusyTimeout = SqliteValueBox.busyTimeoutMilliseconds
        SqliteValueBox.busyTimeoutMilliseconds = 100
    }

    override func tearDown() {
        SqliteValueBox.busyTimeoutMilliseconds = self.savedBusyTimeout
        chmod(self.basePath, 0o755)
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    // MARK: - Helpers

    private var databasePath: String {
        return self.basePath + "/db/db_sqlite"
    }

    private func makeBox(isMainProcess: Bool = true) -> StorageBox {
        return StorageBox(logger: StorageBox.Logger(impl: { _ in }), basePath: self.basePath, isMainProcess: isMainProcess)
    }

    private func itemId(_ index: Int) -> Data {
        return "item-\(index)".data(using: .utf8) ?? Data()
    }

    private func peer(_ id: Int64) -> PeerId {
        return PeerId(namespace: PeerId.Namespace._internalFromInt32Value(0), id: PeerId.Id._internalFromInt64Value(id))
    }

    private func reference(_ peerId: Int64, message: Int32) -> StorageBox.Reference {
        return StorageBox.Reference(peerId: self.peer(peerId).toInt64(), messageNamespace: 0, messageId: message)
    }

    private func first<T>(_ signal: Signal<T, NoError>, timeout: Double = 30.0) -> T? {
        let expectation = self.expectation(description: "signal")
        var result: T?
        let disposable = (signal |> take(1)).start(next: { value in
            result = value
            expectation.fulfill()
        })
        self.wait(for: [expectation], timeout: timeout)
        disposable.dispose()
        return result
    }

    private func addItem(_ box: StorageBox, index: Int, size: Int64) {
        box.add(reference: self.reference(1, message: Int32(clamping: index + 1)), to: self.itemId(index), contentType: self.contentType)
        box.update(id: self.itemId(index), size: size)
    }

    private func storedSize(_ box: StorageBox) -> Int64? {
        return self.first(box.getAllStats())?.total.contentTypes[self.contentType]?.size
    }

    /// A second SQLite connection to the box's file, standing in for another process (an app
    /// extension) that holds the write lock.
    private final class LockingConnection {
        private var handle: OpaquePointer?

        init?(path: String) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard sqlite3_open_v2(path, &self.handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(self.handle)
                return nil
            }
        }

        @discardableResult
        func execute(_ sql: String) -> Bool {
            return sqlite3_exec(self.handle, sql, nil, nil, nil) == SQLITE_OK
        }

        func lock() -> Bool {
            return self.execute("PRAGMA journal_mode=WAL") && self.execute("BEGIN IMMEDIATE")
        }

        func unlock() {
            self.execute("COMMIT")
        }

        deinit {
            sqlite3_close(self.handle)
        }
    }

    // MARK: - The file cannot be opened

    /// `db` is a file instead of a directory and the box's directory is read-only, so neither
    /// SQLite nor a recovery (deleting, test directory) can create anything there.
    private func makeDatabaseUnopenable() {
        FileManager.default.createFile(atPath: self.basePath + "/db", contents: Data("not a directory".utf8))
        chmod(self.basePath, 0o555)
    }

    func testAppBoxWhoseDatabaseCannotBeOpenedKeepsWorkingInMemory() {
        self.makeDatabaseUnopenable()

        let box = self.makeBox(isMainProcess: true)
        self.addItem(box, index: 0, size: 1_000)

        XCTAssertEqual(self.storedSize(box), 1_000, "the index keeps working for this launch, in memory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.basePath + "/db"), "nothing is deleted for a file that could not be opened")
    }

    func testExtensionBoxWhoseDatabaseCannotBeOpenedKeepsWorkingInMemory() {
        self.makeDatabaseUnopenable()

        let box = self.makeBox(isMainProcess: false)
        self.addItem(box, index: 0, size: 2_000)

        XCTAssertEqual(self.storedSize(box), 2_000)
    }

    // MARK: - The file is locked by another process

    func testBoxOpenedWhileAnotherProcessHoldsTheLockKeepsWorkingAndTheNextOpenUsesTheFile() {
        guard let other = LockingConnection(path: self.databasePath), other.lock() else {
            XCTFail("could not lock the database")
            return
        }

        let lockedBox = self.makeBox(isMainProcess: true)
        self.addItem(lockedBox, index: 0, size: 3_000)
        XCTAssertEqual(self.storedSize(lockedBox), 3_000, "the box works while the file is locked")

        other.unlock()

        // The next launch opens the file again and stores to it.
        let box = self.makeBox(isMainProcess: true)
        self.addItem(box, index: 1, size: 4_000)
        XCTAssertEqual(self.storedSize(box), 4_000)
        let reopened = self.makeBox(isMainProcess: true)
        XCTAssertEqual(self.storedSize(reopened), 4_000, "what the unlocked box wrote is in the file")
    }

    func testWritesWhileTheFileIsLockedAreDroppedAndLaterWritesAreStored() {
        let box = self.makeBox(isMainProcess: true)
        // Wait for the open; the item tables are created by the first write that needs them.
        XCTAssertNil(self.storedSize(box))

        guard let other = LockingConnection(path: self.databasePath), other.lock() else {
            XCTFail("could not lock the database")
            return
        }
        // The tables cannot be created now: this write is lost, without a crash.
        self.addItem(box, index: 0, size: 5_000)
        XCTAssertNil(self.storedSize(box))
        other.unlock()

        // Once the lock is gone the tables are created and the write is stored.
        self.addItem(box, index: 1, size: 6_000)
        XCTAssertEqual(self.storedSize(box), 6_000)
        let reopened = self.makeBox(isMainProcess: true)
        XCTAssertEqual(self.storedSize(reopened), 6_000)
    }

    // MARK: - A table cannot be written

    /// The exact device frames: the reindex of a new index writes its metadata row to t21, and
    /// that statement cannot be prepared. Here t21 is a view, so `CREATE TABLE IF NOT EXISTS`
    /// succeeds and the INSERT fails to prepare, as "no such table" did on the device.
    func testMetadataTableThatCannotBeWrittenDoesNotTrapTheReindex() {
        let queue = Queue(name: "StorageBoxUnavailableDatabaseTests")
        queue.sync {
            let valueBox = SqliteValueBox(basePath: self.basePath + "/db", queue: queue, isTemporary: false, isReadOnly: false, useCaches: false, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in })
            XCTAssertNotNil(valueBox)
            valueBox?.internalClose()
        }
        guard let other = LockingConnection(path: self.databasePath) else {
            XCTFail("could not open the database")
            return
        }
        XCTAssertTrue(other.execute("CREATE VIEW t21 AS SELECT 1 AS key, 2 AS value"))

        let box = self.makeBox(isMainProcess: true)
        self.addItem(box, index: 0, size: 7_000)

        XCTAssertEqual(self.storedSize(box), 7_000, "the other tables keep working")
    }
}
