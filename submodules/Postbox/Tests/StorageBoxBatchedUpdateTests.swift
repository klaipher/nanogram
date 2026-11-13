import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// `update(id:size:)` runs for every cached file and downloaded chunk. The calls are applied in
/// batches, one SQLite transaction each. Every other operation must still see them in order,
/// and a process that dies with a batch pending must leave a consistent database.
final class StorageBoxBatchedUpdateTests: XCTestCase {
    private let contentType: UInt8 = 2

    private var basePath = ""

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "StorageBoxBatchedUpdateTests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
    }

    override func tearDown() {
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    /// With the one-second, 64-item batching these tests were written for; the shipped defaults are checked apart.
    private func makeBox() -> StorageBox {
        return StorageBox(logger: StorageBox.Logger(impl: { _ in }), basePath: self.basePath, isMainProcess: true, sizeUpdateDelay: 1.0, maxPendingSizeUpdates: 64)
    }

    private func makeDefaultBox() -> StorageBox {
        return StorageBox(logger: StorageBox.Logger(impl: { _ in }), basePath: self.basePath, isMainProcess: true)
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

    private func first<T>(_ signal: Signal<T, NoError>, timeout: Double = 10.0) -> T? {
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

    private func totalSize(_ box: StorageBox) -> Int64 {
        return self.first(box.getAllStats())?.total.contentTypes.values.reduce(0, { $0 + $1.size }) ?? -1
    }

    /// Sizes of peer 1's items by message id (message ids start at 1; id 0 is not counted).
    private func itemSizes(_ box: StorageBox) -> [Int32: Int64] {
        var result: [Int32: Int64] = [:]
        let messages = self.first(box.getAllStats())?.peers[self.peer(1)]?.contentTypes[self.contentType]?.messages ?? [:]
        for (id, size) in messages {
            result[id.id] = size
        }
        return result
    }

    /// Total of items that were only ever updated, never added (content type 0).
    private func untypedTotal(_ box: StorageBox) -> Int64 {
        return self.first(box.getAllStats())?.total.contentTypes[0]?.size ?? 0
    }

    /// Waits until every call already sent to the box's queue has run.
    private func drain(_ box: StorageBox) {
        let _ = self.first(box.allPeerIds())
    }

    func testStatsReadRightAfterUpdatesSeeThem() {
        let box = self.makeBox()
        for i in 0 ..< 10 {
            box.add(reference: self.reference(1, message: Int32(clamping: i + 1)), to: self.itemId(i), contentType: self.contentType)
            box.update(id: self.itemId(i), size: Int64(100 + i))
        }
        let stats = self.first(box.getAllStats())
        XCTAssertEqual(stats?.total.contentTypes[self.contentType]?.size, (0 ..< 10).reduce(Int64(0), { $0 + Int64(100 + $1) }))
        XCTAssertEqual(stats?.peers[self.peer(1)]?.contentTypes[self.contentType]?.size, 1045)
        XCTAssertEqual(self.itemSizes(box)[4], 103)
        XCTAssertEqual(self.first(box.get(ids: [self.itemId(7)]))?.first?.id, self.itemId(7))
    }

    func testRepeatedUpdatesOfOneItemKeepTheLastSize() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: self.contentType)
        for size in [10, 500, 20, 7_000, 300] as [Int64] {
            box.update(id: self.itemId(0), size: size)
        }
        XCTAssertEqual(self.totalSize(box), 300)
        XCTAssertEqual(self.first(box.getAllStats())?.peers[self.peer(1)]?.contentTypes[self.contentType]?.size, 300)
    }

    func testUpdateOfUnknownItemThenAddKeepsOrder() {
        let box = self.makeBox()
        // Not yet referenced: update creates it with content type 0.
        box.update(id: self.itemId(0), size: 1_000)
        box.add(reference: self.reference(5, message: 9), to: self.itemId(0), contentType: self.contentType)
        let stats = self.first(box.getAllStats())
        XCTAssertEqual(stats?.total.contentTypes[self.contentType]?.size, 1_000)
        XCTAssertEqual(stats?.total.contentTypes[0]?.size ?? 0, 0)
        XCTAssertEqual(stats?.peers[self.peer(5)]?.contentTypes[self.contentType]?.size, 1_000)
    }

    func testRemoveAfterPendingUpdateRemovesTheItem() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: self.contentType)
        box.update(id: self.itemId(0), size: 4_000)
        box.remove(ids: [self.itemId(0)])
        box.update(id: self.itemId(1), size: 50)
        XCTAssertNil(self.itemSizes(box)[1])
        XCTAssertEqual(self.untypedTotal(box), 50)
        XCTAssertEqual(self.first(box.get(ids: [self.itemId(0)]))?.count, 0)
        XCTAssertEqual(self.first(box.getAllStats())?.peers[self.peer(1)]?.contentTypes[self.contentType]?.size ?? 0, 0)
    }

    func testCleanupByPeerSeesPendingUpdates() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: self.contentType)
        box.update(id: self.itemId(0), size: 4_000)
        let expectation = self.expectation(description: "remove")
        var removed: [Data] = []
        box.remove(peerId: self.peer(1), contentTypes: [self.contentType], includeIds: [], excludeIds: [], completion: { ids in
            removed = ids
            expectation.fulfill()
        })
        self.wait(for: [expectation], timeout: 10.0)
        XCTAssertEqual(removed, [self.itemId(0)])
        XCTAssertEqual(self.totalSize(box), 0)
    }

    func testTotalSizeSubscriberSeesUpdatesWithoutAnotherCall() {
        let box = self.makeBox()
        box.update(id: self.itemId(0), size: 123)
        let expectation = self.expectation(description: "total")
        let disposable = box.totalSize().start(next: { value in
            if value == 123 {
                expectation.fulfill()
            }
        })
        self.wait(for: [expectation], timeout: 5.0)
        disposable.dispose()

        // A later update reaches the subscriber on its own, after the batch delay.
        let later = self.expectation(description: "later")
        let laterDisposable = box.totalSize().start(next: { value in
            if value == 456 {
                later.fulfill()
            }
        })
        box.update(id: self.itemId(0), size: 456)
        self.wait(for: [later], timeout: 5.0)
        laterDisposable.dispose()
    }

    func testUpdatesReachDiskWithoutAnotherCall() {
        var box: StorageBox? = self.makeBox()
        box?.update(id: self.itemId(0), size: 77)
        let expectation = self.expectation(description: "delay")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: {
            expectation.fulfill()
        })
        self.wait(for: [expectation], timeout: 5.0)
        if let box {
            self.drain(box)
        }
        box = nil

        let reopened = self.makeBox()
        XCTAssertEqual(self.untypedTotal(reopened), 77)
    }

    private func appliedSizeUpdates(_ box: StorageBox) -> Int {
        return self.first(box.debugState())?.appliedSizeUpdates ?? -1
    }

    func testTheDefaultBatchIsTenSecondsOrTwoHundredFiftySixItems() {
        XCTAssertEqual(StorageBox.defaultSizeUpdateDelay, 10.0)
        XCTAssertEqual(StorageBox.defaultMaxPendingSizeUpdates, 256)

        let box = self.makeDefaultBox()
        for i in 0 ..< 255 {
            box.update(id: self.itemId(i), size: 10)
        }
        XCTAssertEqual(self.appliedSizeUpdates(box), 0, "255 pending items are not written yet")

        box.update(id: self.itemId(255), size: 10)
        XCTAssertEqual(self.appliedSizeUpdates(box), 256, "the 256th item writes the batch")
    }

    func testTheDefaultBatchWaitsMoreThanASecondAndIsWrittenWhenTheAppSuspends() {
        let box = self.makeDefaultBox()
        box.update(id: self.itemId(0), size: 321)
        let wait = self.expectation(description: "delay")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: {
            wait.fulfill()
        })
        self.wait(for: [wait], timeout: 5.0)
        XCTAssertEqual(self.appliedSizeUpdates(box), 0, "not written after the old one-second delay")

        let suspended = self.expectation(description: "suspended")
        box.setCanBeginTransactions(false, afterTransactionIfRunning: {
            suspended.fulfill()
        })
        self.wait(for: [suspended], timeout: 5.0)
        XCTAssertEqual(self.appliedSizeUpdates(box), 1)
    }

    func testReleasingMemoryWritesPendingUpdates() {
        let box = self.makeDefaultBox()
        box.update(id: self.itemId(0), size: 654)
        box.releaseMemory()
        self.drain(box)
        let other = self.makeDefaultBox()
        XCTAssertEqual(self.untypedTotal(other), 654)
    }

    func testSuspendingTransactionsFlushesPendingUpdatesFirst() {
        let box = self.makeBox()
        box.update(id: self.itemId(0), size: 900)
        let expectation = self.expectation(description: "suspended")
        box.setCanBeginTransactions(false, afterTransactionIfRunning: {
            expectation.fulfill()
        })
        self.wait(for: [expectation], timeout: 5.0)

        // A second connection sees the update although the first box no longer writes.
        let other = self.makeBox()
        XCTAssertEqual(self.untypedTotal(other), 900)

        // While suspended, a new update is not written.
        box.update(id: self.itemId(1), size: 5)
        let wait = self.expectation(description: "delay")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: {
            wait.fulfill()
        })
        self.wait(for: [wait], timeout: 5.0)
        XCTAssertEqual(self.untypedTotal(other), 900)

        let resumed = self.expectation(description: "resumed")
        box.setCanBeginTransactions(true, afterTransactionIfRunning: {
            resumed.fulfill()
        })
        self.wait(for: [resumed], timeout: 5.0)
        XCTAssertEqual(self.untypedTotal(box), 905)
    }

    /// A process that dies with updates pending loses at most those updates; what was written
    /// is whole and the totals match the items.
    func testDatabaseStaysConsistentWhenPendingUpdatesAreLost() {
        var box: StorageBox? = self.makeBox()
        for i in 0 ..< 20 {
            box?.add(reference: self.reference(1, message: Int32(clamping: i + 1)), to: self.itemId(i), contentType: self.contentType)
            box?.update(id: self.itemId(i), size: 1_000)
        }
        if let box {
            XCTAssertEqual(self.totalSize(box), 20_000)
        }
        for i in 0 ..< 20 {
            box?.update(id: self.itemId(i), size: 2_000)
        }
        // Dropped without a read, the way a killed process leaves it.
        box = nil

        let reopened = self.makeBox()
        let sizes = self.itemSizes(reopened)
        XCTAssertEqual(sizes.count, 20)
        let itemTotal = sizes.values.reduce(0, +)
        XCTAssertTrue(itemTotal >= 20_000 && itemTotal <= 40_000)
        let stats = self.first(reopened.getAllStats())
        XCTAssertEqual(stats?.total.contentTypes[self.contentType]?.size, itemTotal)
        XCTAssertEqual(stats?.peers[self.peer(1)]?.contentTypes[self.contentType]?.size, itemTotal)
    }

    /// Cost of a burst of size updates, the way a sticker panel stores cached frames.
    func testUpdateBurstBenchmark() {
        let box = self.makeBox()
        let count = 500
        for i in 0 ..< count {
            box.add(reference: self.reference(1, message: Int32(clamping: i + 1)), to: self.itemId(i), contentType: self.contentType)
        }
        self.drain(box)
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0 ..< count {
            box.update(id: self.itemId(i), size: Int64(10 + i))
        }
        let total = self.totalSize(box)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        XCTAssertEqual(total, (0 ..< count).reduce(Int64(0), { $0 + Int64(10 + $1) }))
        print("StorageBox benchmark: \(count) updates + stats read: \(String(format: "%.1f", ms)) ms")
    }
}
