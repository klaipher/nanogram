import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// The last-run time of the cache walkers is kept in the storage index of the account (no server traffic, no UI
/// state), so a relaunch within a day does not walk the cache again.
final class CacheWalkerRecordStoreTests: XCTestCase {
    func testTheTouchSkipIntervalMatchesTheInMemoryDedupe() {
        XCTAssertEqual(CacheTouchPolicy.skipInterval, RecentFileTouches.defaultInterval)
    }

    func testTheRunRecordSurvivesReopeningTheStorageBox() {
        let basePath = NSTemporaryDirectory() + "CacheWalkerRecord-" + UUID().uuidString
        defer {
            let _ = try? FileManager.default.removeItem(atPath: basePath)
        }
        func read(_ box: StorageBox, _ name: String) -> CacheWalkerRecord? {
            let semaphore = DispatchSemaphore(value: 0)
            var result: CacheWalkerRecord?
            let disposable = box.cacheWalkerRecord(name: name).start(next: { value in
                result = value
                semaphore.signal()
            })
            XCTAssertEqual(semaphore.wait(timeout: .now() + 10.0), .success)
            disposable.dispose()
            return result
        }
        do {
            let box = StorageBox(logger: StorageBox.Logger(impl: { _ in }), basePath: basePath, isMainProcess: true)
            XCTAssertNil(read(box, "scan"))
            box.setCacheWalkerRecord(CacheWalkerRecord(completedAt: 1234.5, fingerprint: "limits"), name: "scan")
            XCTAssertEqual(read(box, "scan"), CacheWalkerRecord(completedAt: 1234.5, fingerprint: "limits"))
            XCTAssertNil(read(box, "eviction"))
        }
        let reopened = StorageBox(logger: StorageBox.Logger(impl: { _ in }), basePath: basePath, isMainProcess: true)
        XCTAssertEqual(read(reopened, "scan"), CacheWalkerRecord(completedAt: 1234.5, fingerprint: "limits"))
        XCTAssertNil(read(reopened, "eviction"))
    }
}
