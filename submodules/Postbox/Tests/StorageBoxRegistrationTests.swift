import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// MediaBox registers a resource with `add` on every request of a file that is not complete yet.
/// Most of those calls repeat a registration that is already stored, so they are answered from
/// memory instead of a write transaction. Everything that can undo a registration must make the
/// next `add` write again. Also covers coalescing size updates by id and opening the database
/// lazily in app extensions.
final class StorageBoxRegistrationTests: XCTestCase {
    private var basePath = ""

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "StorageBoxRegistrationTests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
    }

    override func tearDown() {
        StorageBox.registrationCacheCapacity = StorageBox.defaultRegistrationCacheCapacity
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
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

    private func state(_ box: StorageBox) -> StorageBox.DebugState {
        return self.first(box.debugState()) ?? StorageBox.DebugState(transactions: -1)
    }

    private func references(_ box: StorageBox, _ index: Int) -> Int {
        return self.first(box.get(ids: [self.itemId(index)]))?.first?.references.count ?? 0
    }

    private func contentTypeSize(_ box: StorageBox, _ contentType: UInt8) -> Int64 {
        return self.first(box.getAllStats())?.total.contentTypes[contentType]?.size ?? 0
    }

    private func setCanBeginTransactions(_ box: StorageBox, _ value: Bool) {
        let expectation = self.expectation(description: "set")
        box.setCanBeginTransactions(value, afterTransactionIfRunning: {
            expectation.fulfill()
        })
        self.wait(for: [expectation], timeout: 10.0)
    }

    private func databaseExists() -> Bool {
        return FileManager.default.fileExists(atPath: self.basePath + "/db/db_sqlite")
    }

    // MARK: - add() skip

    func testRepeatedAddWritesOnce() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        let before = self.state(box).transactions
        for _ in 0 ..< 50 {
            box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        }
        XCTAssertEqual(self.state(box).transactions, before)
        XCTAssertEqual(self.references(box, 0), 1)
    }

    func testAddWithAnotherReferenceIsWritten() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.add(reference: self.reference(1, message: 2), to: self.itemId(0), contentType: 2)
        box.add(reference: self.reference(3, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.references(box, 0), 3)
    }

    func testContentTypeChangedBackIsWritten() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.update(id: self.itemId(0), size: 100)
        // The same reference with another type, from another call site.
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 3)
        XCTAssertEqual(self.contentTypeSize(box, 3), 100)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.contentTypeSize(box, 2), 100)
        XCTAssertEqual(self.contentTypeSize(box, 3), 0)
    }

    func testContentTypeChangedByAnotherReferenceIsWrittenBack() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.update(id: self.itemId(0), size: 100)
        box.add(reference: self.reference(1, message: 2), to: self.itemId(0), contentType: 3)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.contentTypeSize(box, 2), 100)
    }

    func testAddAfterRemoveIsWritten() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.remove(ids: [self.itemId(0)])
        XCTAssertEqual(self.references(box, 0), 0)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.references(box, 0), 1)
    }

    func testAddAfterResetIsWritten() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.reset()
        XCTAssertEqual(self.references(box, 0), 0)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.references(box, 0), 1)
    }

    func testAddAfterRemoveByPeerIsWritten() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.update(id: self.itemId(0), size: 10)
        let removed = self.expectation(description: "removed")
        box.remove(peerId: self.peer(1), contentTypes: [2], includeIds: [], excludeIds: [], completion: { _ in
            removed.fulfill()
        })
        self.wait(for: [removed], timeout: 10.0)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.references(box, 0), 1)

        let removedAgain = self.expectation(description: "removed again")
        box.remove(peerIds: Set([self.peer(1)]), includeIds: [], excludeIds: [], completion: { _ in
            removedAgain.fulfill()
        })
        self.wait(for: [removedAgain], timeout: 10.0)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.references(box, 0), 1)
    }

    func testBatchAddTypeChangeIsWrittenBack() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.batchAdd(items: [(reference: self.reference(1, message: 1), id: self.itemId(0), contentType: 4, size: 50)])
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.contentTypeSize(box, 2), 50)
    }

    /// While suspended, operations are queued. A remove queued after an add must still make a later
    /// add write again.
    func testQueuedAddThenRemoveWhileSuspended() {
        let box = self.makeBox()
        self.setCanBeginTransactions(box, false)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.remove(ids: [self.itemId(0)])
        self.setCanBeginTransactions(box, true)
        XCTAssertEqual(self.references(box, 0), 0)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.references(box, 0), 1)
    }

    func testQueuedRemoveThenAddWhileSuspended() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        self.setCanBeginTransactions(box, false)
        box.remove(ids: [self.itemId(0)])
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        self.setCanBeginTransactions(box, true)
        XCTAssertEqual(self.references(box, 0), 1)
    }

    func testCacheIsBounded() {
        StorageBox.registrationCacheCapacity = 4
        let box = self.makeBox()
        for i in 0 ..< 20 {
            box.add(reference: self.reference(1, message: 1), to: self.itemId(i), contentType: 2)
        }
        XCTAssertLessThanOrEqual(self.state(box).registrationCacheCount, 8)
        // An evicted registration is simply written again.
        let before = self.state(box).transactions
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertEqual(self.state(box).transactions, before + 1)
        XCTAssertEqual(self.references(box, 0), 1)
    }

    /// The device mix measured for the research: 3 of 4 calls re-register a known item.
    func testRepeatedAddBenchmark() {
        let count = 4000
        func run(capacity: Int) -> (ms: Double, transactions: Int) {
            StorageBox.registrationCacheCapacity = capacity
            let path = self.basePath + "/bench-\(capacity)"
            let box = StorageBox(logger: StorageBox.Logger(impl: { _ in }), basePath: path, isMainProcess: true)
            let start0 = self.state(box).transactions
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0 ..< count {
                let item = i % 4 == 0 ? i : (i / 4) * 4
                box.add(reference: self.reference(1, message: Int32(clamping: item % 100)), to: self.itemId(item), contentType: 2)
            }
            let end = self.state(box)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return (ms, end.transactions - start0)
        }
        let uncached = run(capacity: 0)
        let cached = run(capacity: StorageBox.defaultRegistrationCacheCapacity)
        XCTAssertEqual(uncached.transactions, count)
        XCTAssertEqual(cached.transactions, count / 4)
        print("StorageBox add benchmark: \(count) adds (75% repeats): uncached \(String(format: "%.1f", uncached.ms)) ms / \(uncached.transactions) tx, cached \(String(format: "%.1f", cached.ms)) ms / \(cached.transactions) tx")
    }

    // MARK: - update() coalescing

    func testUpdatesOfOneItemInABatchApplyOnce() {
        let box = self.makeBox()
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        let before = self.state(box).appliedSizeUpdates
        for size in 1 ... 40 {
            box.update(id: self.itemId(0), size: Int64(size * 10))
        }
        XCTAssertEqual(self.contentTypeSize(box, 2), 400)
        XCTAssertEqual(self.state(box).appliedSizeUpdates - before, 1)
    }

    func testCoalescedUpdatesKeepEachItemsLastSize() {
        let box = self.makeBox()
        box.update(id: self.itemId(0), size: 1)
        box.update(id: self.itemId(1), size: 2)
        box.update(id: self.itemId(0), size: 3)
        box.update(id: self.itemId(2), size: 0)
        box.update(id: self.itemId(1), size: 5)
        // Unknown items are created with content type 0.
        XCTAssertEqual(self.contentTypeSize(box, 0), 8)
        XCTAssertEqual(self.state(box).appliedSizeUpdates, 3)
    }

    /// A batch is written once it holds this many distinct items, not this many calls.
    func testBatchLimitCountsDistinctItems() {
        let box = self.makeBox()
        for _ in 0 ..< 3 {
            for i in 0 ..< 63 {
                box.update(id: self.itemId(i), size: Int64(i + 1))
            }
        }
        let pending = self.state(box)
        XCTAssertEqual(pending.appliedSizeUpdates, 0)
        box.update(id: self.itemId(63), size: 64)
        XCTAssertEqual(self.state(box).appliedSizeUpdates, 64)
    }

    // MARK: - Lazy open in extensions

    func testExtensionBoxOpensOnFirstUse() {
        let box = self.makeBox(isMainProcess: false)
        XCTAssertFalse(self.state(box).isOpen)
        box.releaseMemory()
        self.setCanBeginTransactions(box, true)
        XCTAssertFalse(self.state(box).isOpen)
        XCTAssertFalse(self.databaseExists())

        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        XCTAssertTrue(self.state(box).isOpen)
        XCTAssertTrue(self.databaseExists())
        XCTAssertEqual(self.references(box, 0), 1)
    }

    func testMainProcessBoxOpensRightAway() {
        let box = self.makeBox(isMainProcess: true)
        XCTAssertTrue(self.state(box).isOpen)
    }

    /// Suspended before first use: nothing opens the database until transactions are allowed
    /// again, and work requested meanwhile runs then, in order.
    func testExtensionBoxSuspendedBeforeFirstUse() {
        let box = self.makeBox(isMainProcess: false)
        self.setCanBeginTransactions(box, false)
        box.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        box.update(id: self.itemId(0), size: 70)
        var stats: StorageBox.AllStats?
        let read = box.getAllStats().start(next: { value in
            stats = value
        })
        let wait = self.expectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: {
            wait.fulfill()
        })
        self.wait(for: [wait], timeout: 5.0)
        XCTAssertFalse(self.state(box).isOpen)
        XCTAssertFalse(self.databaseExists())
        XCTAssertNil(stats)

        self.setCanBeginTransactions(box, true)
        XCTAssertTrue(self.state(box).isOpen)
        XCTAssertEqual(self.contentTypeSize(box, 2), 70)
        XCTAssertNotNil(stats)
        read.dispose()
    }

    func testExtensionBoxSeesWhatTheAppWrote() {
        let app = self.makeBox(isMainProcess: true)
        app.add(reference: self.reference(1, message: 1), to: self.itemId(0), contentType: 2)
        app.update(id: self.itemId(0), size: 33)
        XCTAssertEqual(self.contentTypeSize(app, 2), 33)

        let extensionBox = self.makeBox(isMainProcess: false)
        XCTAssertEqual(self.contentTypeSize(extensionBox, 2), 33)
    }
}
