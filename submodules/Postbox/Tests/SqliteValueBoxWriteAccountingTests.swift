import Foundation
import XCTest
import SwiftSignalKit
import DiskWriteAccounting
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
}
