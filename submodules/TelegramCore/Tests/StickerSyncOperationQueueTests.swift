import Foundation
import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

// Pins the operation-log queue that the recent-sticker, saved-GIF and faved-sticker sync workers run.
// A `.sync` request must queue one sync entry, not two: the workers run entries one by one, so a second
// sync right behind the first only repeats the same fetch (manageStickerPacks asks for `.sync` at every
// launch and every hour). A local change (add, remove, clear) is still followed by one sync.
final class StickerSyncOperationQueueTests: XCTestCase {
    private var postbox: Postbox?
    private var directory: URL?

    override func setUpWithError() throws {
        initializeAccountManagement()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-sync-queue-tests-" + UUID().uuidString)
        self.directory = directory
        let encryption = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: false, key: try XCTUnwrap(.init(data: Data(count: 32))), salt: try XCTUnwrap(.init(data: Data(count: 16))))
        let opened = try value(openPostbox(basePath: directory.path, seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: encryption, timestampForAbsoluteTimeBasedOperations: Int32(clamping: Int64(Date().timeIntervalSince1970.rounded(.down))), isMainProcess: true, isTemporary: false, isReadOnly: false, useCopy: false, useCaches: true, removeDatabaseOnError: false)
            |> filter { result in
                if case .upgrading = result { return false }
                return true
            })
        guard case let .postbox(postbox) = opened else {
            throw NSError(domain: "StickerSyncOperationQueueTests", code: 1)
        }
        self.postbox = postbox
    }

    override func tearDownWithError() throws {
        if let postbox = postbox {
            let _ = try value(postbox.transaction { _ in })
            let _ = try value(postbox.mediaBox.storageBox.all())
            let _ = try value(postbox.mediaBox.cacheStorageBox.all())
            postbox.mediaBox.dataQueue.sync {}
        }
        postbox = nil
        Postbox.sharedQueue.sync {}
        if let directory = directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func value<T>(_ signal: Signal<T, NoError>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let completed = expectation(description: "signal completed")
        let result = Atomic<T?>(value: nil)
        let disposable = (signal |> take(1)).start(next: { value in
            let _ = result.swap(value)
        }, completed: { completed.fulfill() })
        defer { disposable.dispose() }
        wait(for: [completed], timeout: 15)
        return try XCTUnwrap(result.with { $0 }, file: file, line: line)
    }

    private func openedPostbox() throws -> Postbox {
        return try XCTUnwrap(postbox)
    }

    private func perform(_ f: @escaping (Transaction) -> Void) throws {
        let _ = try value(openedPostbox().transaction { transaction -> Void in
            f(transaction)
        })
    }

    private func queuedKinds(tag: PeerOperationLogTag) throws -> [String] {
        return try value(openedPostbox().transaction { transaction -> [String] in
            var kinds: [String] = []
            transaction.operationLogEnumerateEntries(peerId: PeerId(0), tag: tag) { entry in
                if let operation = entry.contents as? SynchronizeRecentlyUsedMediaOperation {
                    switch operation.content {
                    case .add:
                        kinds.append("add")
                    case .remove:
                        kinds.append("remove")
                    case .clear:
                        kinds.append("clear")
                    case .sync:
                        kinds.append("sync")
                    }
                } else if let operation = entry.contents as? SynchronizeSavedGifsOperation {
                    switch operation.content {
                    case .add:
                        kinds.append("add")
                    case .remove:
                        kinds.append("remove")
                    case .sync:
                        kinds.append("sync")
                    }
                } else if let operation = entry.contents as? SynchronizeSavedStickersOperation {
                    switch operation.content {
                    case .add:
                        kinds.append("add")
                    case .remove:
                        kinds.append("remove")
                    case .sync:
                        kinds.append("sync")
                    }
                } else {
                    kinds.append("unknown")
                }
                return true
            }
            return kinds
        })
    }

    // MARK: - Recently used stickers

    func testRecentStickersSyncQueuesOneEntry() throws {
        try perform { addSynchronizeRecentlyUsedMediaOperation(transaction: $0, category: .stickers, operation: .sync) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeRecentlyUsedStickers), ["sync"])
    }

    func testRecentStickersRepeatedSyncStaysOneEntry() throws {
        try perform { addSynchronizeRecentlyUsedMediaOperation(transaction: $0, category: .stickers, operation: .sync) }
        try perform { addSynchronizeRecentlyUsedMediaOperation(transaction: $0, category: .stickers, operation: .sync) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeRecentlyUsedStickers), ["sync"])
    }

    func testRecentStickersLocalChangesAreFollowedByOneSync() throws {
        try perform { addSynchronizeRecentlyUsedMediaOperation(transaction: $0, category: .stickers, operation: .add(id: 1, accessHash: 1, fileReference: nil)) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeRecentlyUsedStickers), ["add", "sync"])
    }

    func testRecentStickersRemoveAndClearAreFollowedByOneSync() throws {
        try perform { addSynchronizeRecentlyUsedMediaOperation(transaction: $0, category: .stickers, operation: .remove(id: 1, accessHash: 1)) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeRecentlyUsedStickers), ["remove", "sync"])

        try perform { addSynchronizeRecentlyUsedMediaOperation(transaction: $0, category: .stickers, operation: .clear) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeRecentlyUsedStickers), ["remove", "sync", "clear", "sync"])
    }

    // MARK: - Saved GIFs

    func testSavedGifsSyncQueuesOneEntry() throws {
        try perform { addSynchronizeSavedGifsOperation(transaction: $0, operation: .sync) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedGifs), ["sync"])
    }

    func testSavedGifsRepeatedSyncStaysOneEntry() throws {
        try perform { addSynchronizeSavedGifsOperation(transaction: $0, operation: .sync) }
        try perform { addSynchronizeSavedGifsOperation(transaction: $0, operation: .sync) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedGifs), ["sync"])
    }

    func testSavedGifsLocalChangesAreFollowedByOneSync() throws {
        try perform { addSynchronizeSavedGifsOperation(transaction: $0, operation: .add(id: 1, accessHash: 1, fileReference: nil)) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedGifs), ["add", "sync"])

        try perform { addSynchronizeSavedGifsOperation(transaction: $0, operation: .remove(id: 1, accessHash: 1)) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedGifs), ["add", "sync", "remove", "sync"])
    }

    // MARK: - Faved (saved) stickers

    func testSavedStickersSyncQueuesOneEntry() throws {
        try perform { addSynchronizeSavedStickersOperation(transaction: $0, operation: .sync) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedStickers), ["sync"])
    }

    func testSavedStickersRepeatedSyncStaysOneEntry() throws {
        try perform { addSynchronizeSavedStickersOperation(transaction: $0, operation: .sync) }
        try perform { addSynchronizeSavedStickersOperation(transaction: $0, operation: .sync) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedStickers), ["sync"])
    }

    func testSavedStickersLocalChangesAreFollowedByOneSync() throws {
        try perform { addSynchronizeSavedStickersOperation(transaction: $0, operation: .add(id: 1, accessHash: 1, fileReference: nil)) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedStickers), ["add", "sync"])

        try perform { addSynchronizeSavedStickersOperation(transaction: $0, operation: .remove(id: 1, accessHash: 1)) }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedStickers), ["add", "sync", "remove", "sync"])
    }

    // manageStickerPacks asks all three lists for `.sync` at start and then every hour.
    func testManageStickerPacksStyleRoundsQueueOneSyncPerList() throws {
        for _ in 0 ..< 2 {
            try perform { transaction in
                addSynchronizeRecentlyUsedMediaOperation(transaction: transaction, category: .stickers, operation: .sync)
                addSynchronizeSavedGifsOperation(transaction: transaction, operation: .sync)
                addSynchronizeSavedStickersOperation(transaction: transaction, operation: .sync)
            }
        }
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeRecentlyUsedStickers), ["sync"])
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedGifs), ["sync"])
        XCTAssertEqual(try queuedKinds(tag: OperationLogTags.SynchronizeSavedStickers), ["sync"])
    }
}
