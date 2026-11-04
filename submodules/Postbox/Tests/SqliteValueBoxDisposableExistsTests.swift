import Foundation
import XCTest
import SwiftSignalKit
import sqlcipher
@testable import Postbox

/// A disposable database (`SqliteValueBox.isDisposable`, the StorageBox index) never traps on a
/// failed statement. The Mac's `exists` runs its own statement (iOS goes through `get`), so it must
/// pass the box's trap policy to `step` like every other read. Without it a corrupt StorageBox file
/// in the app (`removeDatabaseOnError`) still crashed on `StorageBox.add`/`update`, which call
/// `exists`, and strict error handling trapped on any step error.
final class SqliteValueBoxDisposableExistsTests: XCTestCase {
    private var basePath = ""

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "SqliteValueBoxDisposableExistsTests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
    }

    override func tearDown() {
        setValueBoxStrictErrorHandling(false)
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    func testExistsOnADisposableDatabaseDoesNotTrapWhenItsStatementFails() {
        let queue = Queue(name: "SqliteValueBoxDisposableExistsTests")
        let table = ValueBoxTable(id: 7, keyType: .int64, compactValuesOnCreation: false)
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: 1)

        queue.sync {
            let valueBox = SqliteValueBox(basePath: self.basePath, queue: queue, isTemporary: false, isReadOnly: false, useCaches: false, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in }, isDisposable: true)
            XCTAssertNotNil(valueBox)
            valueBox?.internalClose()
        }

        // t7 is a view whose row filter fails at step time (integer overflow), so the exists
        // statement prepares and then its step returns an error.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(self.basePath + "/db_sqlite", &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE VIEW t7 AS SELECT 1 AS key, x'00' AS value WHERE abs(-9223372036854775808) > 0", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        queue.sync {
            guard let valueBox = SqliteValueBox(basePath: self.basePath, queue: queue, isTemporary: false, isReadOnly: false, useCaches: false, removeDatabaseOnError: true, encryptionParameters: nil, upgradeProgress: { _ in }, isDisposable: true) else {
                XCTFail("could not open the database")
                return
            }
            // Records t7 (CREATE TABLE IF NOT EXISTS succeeds on the view); the insert is dropped.
            valueBox.set(table, key: key, value: MemoryBuffer(data: Data([1])))

            setValueBoxStrictErrorHandling(true)
            XCTAssertFalse(valueBox.exists(table, key: key), "a failed step finds nothing and does not trap")
            XCTAssertNil(valueBox.get(table, key: key))
            setValueBoxStrictErrorHandling(false)
            valueBox.internalClose()
        }
    }
}
