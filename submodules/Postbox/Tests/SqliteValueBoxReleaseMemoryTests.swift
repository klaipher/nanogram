import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// When the app goes to the background, `Postbox.clearCaches()` also returns SQLite's page cache
/// (up to 2 MB per connection by default) to the system. Pages are read back on demand, so the
/// data must stay readable afterwards.
final class SqliteValueBoxReleaseMemoryTests: XCTestCase {
    private let table = ValueBoxTable(id: 1001, keyType: .int64, compactValuesOnCreation: true)

    private var queue: Queue!
    private var basePath: String!
    private var valueBox: SqliteValueBox!

    override func setUp() {
        super.setUp()
        self.queue = Queue(name: "SqliteValueBoxReleaseMemoryTests")
        self.basePath = NSTemporaryDirectory() + "SqliteValueBoxReleaseMemoryTests-" + UUID().uuidString
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

    private func key(_ value: Int64) -> ValueBoxKey {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: value)
        return key
    }

    func testReleasingMemoryEmptiesThePageCacheAndKeepsTheData() {
        let count = 3000
        self.queue.sync {
            self.valueBox.begin()
            let buffer = WriteBuffer()
            for i in 0 ..< count {
                buffer.reset()
                var payload = [UInt8](repeating: UInt8(i % 251), count: 512)
                buffer.write(&payload, offset: 0, length: payload.count)
                self.valueBox.set(self.table, key: self.key(Int64(i)), value: buffer)
            }
            self.valueBox.commit()

            var readCount = 0
            self.valueBox.scanInt64(self.table, values: { _, _ in
                readCount += 1
                return true
            })
            XCTAssertEqual(readCount, count)

            let before = self.valueBox.pageCacheMemoryUsed()
            XCTAssertGreaterThan(before, 512 * 1024, "the scan should have filled the page cache")

            self.valueBox.releaseMemory()
            let after = self.valueBox.pageCacheMemoryUsed()
            XCTAssertLessThan(after, before / 4, "page cache \(before) -> \(after) bytes")
            print("BENCH sqlite page cache: \(before) -> \(after) bytes after releaseMemory")

            for i in [0, 1234, count - 1] {
                let value = self.valueBox.get(self.table, key: self.key(Int64(i)))
                XCTAssertEqual(value?.length, 512)
                if let value = value {
                    XCTAssertEqual(value.memory.assumingMemoryBound(to: UInt8.self)[0], UInt8(i % 251))
                }
            }
        }
    }
}
