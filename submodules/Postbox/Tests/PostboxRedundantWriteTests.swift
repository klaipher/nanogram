import Foundation
import XCTest
import SwiftSignalKit
import sqlcipher
@testable import Postbox

/// Writes that store what is already stored, and decoded values read again on every view
/// update: identical cached data, a validation re-store of an unchanged message, a sync
/// that replaces an ordered list with itself, and the media and thread-summary caches.
final class PostboxRedundantWriteTests: XCTestCase {
    private var fixture: PostboxFixture!
    private let namespace = PostboxFixture.messageNamespace

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "PostboxRedundantWriteTests")
    }

    override func tearDown() {
        self.fixture?.close()
        self.fixture = nil
        super.tearDown()
    }

    private func peerId(_ id: Int64) -> PeerId {
        return MessageHistoryTableFixture.peerId(id)
    }

    // MARK: - Cached peer data

    func testIdenticalCachedDataIsNeitherStoredNorReported() {
        let peerId = self.peerId(10)
        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in FixtureCachedPeerData(peerIds: [self.peerId(11)]) })
        }
        let recorder = self.fixture.observe(.cachedPeerData(peerId: peerId), as: CachedPeerDataView.self)
        recorder.waitForValues(count: 1)

        // A new instance that encodes the same, and the current instance itself.
        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in FixtureCachedPeerData(peerIds: [self.peerId(11)]) })
        }
        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, current in current })
        }
        self.fixture.transaction { _ in }
        XCTAssertEqual(recorder.values.count, 1, "no change, no update")

        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in FixtureCachedPeerData(peerIds: [self.peerId(12)]) })
        }
        let values = recorder.waitForValues(count: 2)
        XCTAssertEqual((values.last?.cachedPeerData as? FixtureCachedPeerData)?.peerIds, [self.peerId(12)])
        let stored = self.fixture.transaction { transaction in
            return transaction.getPeerCachedData(peerId: peerId) as? FixtureCachedPeerData
        }
        XCTAssertEqual(stored??.peerIds, [self.peerId(12)])
    }

    // MARK: - Validation re-store (measurement)

    private func walBytes(_ fixture: PostboxFixture) -> Int {
        let path = fixture.basePath + "/db/db_sqlite-wal"
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Checkpoints and empties the WAL from a second connection, as another process can.
    private func truncateWal(_ fixture: PostboxFixture) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(fixture.basePath + "/db/db_sqlite", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            XCTFail("cannot open the test database")
            return
        }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
    }

    /// History validation used to store every validated message again, unchanged, with a
    /// new stable version. Measured on synthetic data (a file database, 50 messages of 400
    /// characters in an open history view): WAL bytes, view updates and time per batch,
    /// re-storing versus skipping. Logged as BENCHMARK.
    func testBenchmarkValidationRestoreOfUnchangedMessages() {
        self.fixture.close()
        self.fixture = nil
        var results: [String] = []
        var walByMode: [Bool: Int] = [:]
        var updatesByMode: [Bool: Int] = [:]
        for skip in [false, true] {
            let fixture = PostboxFixture(name: "PostboxRedundantWriteTests-validation", inMemory: false)
            defer { fixture.close() }
            let peerId = self.peerId(20)
            let text = String(repeating: "x", count: 400)
            fixture.transaction { transaction in
                transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Channel")], update: { _, updated in updated })
                var messages: [StoreMessage] = []
                for i in 1 ... 200 {
                    messages.append(MessageHistoryTableFixture.storeMessage(id: MessageId(peerId: peerId, namespace: self.namespace, id: Int32(clamping: i)), timestamp: Int32(clamping: 1000 + i), text: text, flags: [.Incoming]))
                }
                let _ = transaction.addMessages(messages, location: .Random)
            }
            let history = fixture.observe(fixture.postbox.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: nil), anchor: .upperBound, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: [], count: 50, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tag: nil, appendMessagesFromTheSameGroup: false, namespaces: .all, orderStatistics: [], additionalData: []) |> map { $0.0 })
            history.waitForValues(count: 1)
            fixture.transaction { _ in }
            let initialCount = history.values.count
            let validatedIds = (151 ... 200).map { MessageId(peerId: peerId, namespace: self.namespace, id: Int32(clamping: $0)) }
            let stableVersions: () -> [UInt32] = {
                return fixture.transaction { transaction in
                    return validatedIds.map { transaction.getMessage($0)?.stableVersion ?? 0 }
                } ?? []
            }
            let initialVersions = stableVersions()
            self.truncateWal(fixture)
            let walBefore = self.walBytes(fixture)

            let start = CFAbsoluteTimeGetCurrent()
            fixture.transaction { transaction in
                for i in 151 ... 200 {
                    transaction.updateMessage(MessageId(peerId: peerId, namespace: self.namespace, id: Int32(clamping: i)), update: { current in
                        if skip {
                            return .skip
                        }
                        // What validation stored before: the message as it is.
                        return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: nil, authorId: current.author?.id, text: current.text, attributes: current.attributes, media: current.media))
                    })
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            fixture.transaction { _ in }
            let wal = self.walBytes(fixture) - walBefore
            let updates = history.values.count - initialCount
            let rewritten = zip(initialVersions, stableVersions()).filter { $0 != $1 }.count
            walByMode[skip] = wal
            updatesByMode[skip] = updates
            results.append("\(skip ? "skip" : "re-store"): \(rewritten) of 50 rows rewritten, \(wal) WAL bytes, \(updates) history view updates, \(String(format: "%.2f", elapsed * 1000.0)) ms")
        }
        NSLog("BENCHMARK validation of 50 unchanged messages: %@", results.joined(separator: "; "))
        XCTAssertLessThan(walByMode[true] ?? Int.max, walByMode[false] ?? 0)
        XCTAssertEqual(updatesByMode[true], 0)
        self.fixture = PostboxFixture(name: "PostboxRedundantWriteTests")
    }

    // MARK: - Ordered item lists

    private func entry(_ id: Int, _ content: String) -> OrderedItemListEntry {
        var value = Int64(id)
        return OrderedItemListEntry(id: MemoryBuffer(data: Data(bytes: &value, count: 8)), contents: CodableEntry(data: content.data(using: .utf8) ?? Data()))
    }

    private func describe(_ items: [OrderedItemListEntry]) -> [String] {
        return items.map { "\($0.id.makeData().base64EncodedString())=\(String(data: $0.contents.data, encoding: .utf8) ?? "")" }
    }

    func testReplacingAnOrderedListWithItselfWritesAndReportsNothing() {
        let collectionId: Int32 = 5
        let items = (0 ..< 20).map { self.entry($0, "item \($0)") }
        self.fixture.transaction { transaction in
            transaction.replaceOrderedItemListItems(collectionId: collectionId, items: items)
        }
        let recorder = self.fixture.observe(.orderedItemList(id: collectionId), as: OrderedItemListView.self)
        recorder.waitForValues(count: 1)

        self.fixture.transaction { transaction in
            transaction.replaceOrderedItemListItems(collectionId: collectionId, items: (0 ..< 20).map { self.entry($0, "item \($0)") })
        }
        self.fixture.transaction { _ in }
        XCTAssertEqual(recorder.values.count, 1, "an identical list is not a change")

        var changed = items
        changed[3] = self.entry(3, "changed")
        self.fixture.transaction { transaction in
            transaction.replaceOrderedItemListItems(collectionId: collectionId, items: changed)
        }
        let values = recorder.waitForValues(count: 2)
        XCTAssertEqual(self.describe(values.last?.items ?? []), self.describe(changed))
    }

    /// Random replaces, moves, removals and updates against a model of the list. Writing
    /// the new list over the old one must leave exactly what deleting and re-inserting did
    /// (`testIntegrity` also asserts it in debug builds).
    func testRandomOrderedListChangesMatchAModel() {
        let collectionId: Int32 = 9
        var random = FixtureRandom(seed: 42)
        var model: [OrderedItemListEntry] = []
        for step in 0 ..< 300 {
            self.fixture.transaction { transaction in
                switch random.int(4) {
                case 0, 1:
                    var ids = Array(0 ..< 30).filter { _ in random.int(3) != 0 }
                    for i in (1 ..< max(ids.count, 1)).reversed() {
                        ids.swapAt(i, random.int(i + 1))
                    }
                    model = ids.map { self.entry($0, "v\(random.int(3))") }
                    transaction.replaceOrderedItemListItems(collectionId: collectionId, items: model)
                case 2:
                    let item = self.entry(random.int(30), "v\(random.int(3))")
                    transaction.addOrMoveToFirstPositionOrderedItemListItem(collectionId: collectionId, item: item, removeTailIfCountExceeds: 25)
                    model.removeAll(where: { $0.id == item.id })
                    model.insert(item, at: 0)
                    if model.count > 25 {
                        model.removeLast(model.count - 25)
                    }
                default:
                    if !model.isEmpty {
                        let index = random.int(model.count)
                        transaction.removeOrderedItemListItem(collectionId: collectionId, itemId: model[index].id)
                        model.remove(at: index)
                    }
                }
            }
            let stored = self.fixture.transaction { transaction in
                return transaction.getOrderedListItems(collectionId: collectionId)
            }
            XCTAssertEqual(self.describe(stored ?? []), self.describe(model), "step \(step)")
            if self.describe(stored ?? []) != self.describe(model) {
                break
            }
        }
    }

    /// Benchmark (synthetic): reading a 300-item list with 200-byte contents, one lookup per
    /// item (what `getItems` does) versus one range scan of the contents. Logged as
    /// BENCHMARK. In an optimized build the scan was not faster (0.233 vs 0.244 ms).
    func testBenchmarkOrderedListRead() {
        let tables = MessageHistoryTableFixture(name: "PostboxRedundantWriteTests-ordered")
        defer { tables.close() }
        let indexTable = OrderedItemListIndexTable(valueBox: tables.valueBox, table: OrderedItemListIndexTable.tableSpec(301), useCaches: false)
        let listTable = OrderedItemListTable(valueBox: tables.valueBox, table: OrderedItemListTable.tableSpec(300), useCaches: false, indexTable: indexTable)
        let content = String(repeating: "c", count: 200)
        let items = (0 ..< 300).map { self.entry($0, content + "\($0)") }
        var result = ""
        tables.queue.sync {
            tables.valueBox.begin()
            var operations: [Int32: [OrderedItemListOperation]] = [:]
            listTable.replaceItems(collectionId: 1, items: items, operations: &operations)
            tables.valueBox.commit()

            tables.valueBox.begin()
            let rounds = 100
            var start = CFAbsoluteTimeGetCurrent()
            var count = 0
            for _ in 0 ..< rounds {
                for id in listTable.getItemIds(collectionId: 1) {
                    if indexTable.get(collectionId: 1, id: id) != nil {
                        count += 1
                    }
                }
            }
            let perItem = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 / Double(rounds)
            start = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< rounds {
                let contents = indexTable.getAll(collectionId: 1)
                for id in listTable.getItemIds(collectionId: 1) {
                    if contents[id] != nil {
                        count += 1
                    }
                }
            }
            let scan = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 / Double(rounds)
            tables.valueBox.commit()
            XCTAssertEqual(count, 2 * rounds * items.count)
            result = String(format: "lookup per item %.3f ms, one scan %.3f ms per 300-item read", perItem, scan)
        }
        NSLog("BENCHMARK ordered list read: %@", result)
    }

    /// Benchmark (synthetic): replacing a 300-item list with an identical copy (now: compared,
    /// nothing written) versus with one item changed (written). Logged as BENCHMARK.
    func testBenchmarkIdenticalOrderedListReplace() {
        let tables = MessageHistoryTableFixture(name: "PostboxRedundantWriteTests-replace")
        defer { tables.close() }
        let indexTable = OrderedItemListIndexTable(valueBox: tables.valueBox, table: OrderedItemListIndexTable.tableSpec(301), useCaches: false)
        let listTable = OrderedItemListTable(valueBox: tables.valueBox, table: OrderedItemListTable.tableSpec(300), useCaches: false, indexTable: indexTable)
        let content = String(repeating: "c", count: 200)
        let items = (0 ..< 300).map { self.entry($0, content + "\($0)") }
        var result = ""
        tables.queue.sync {
            var operations: [Int32: [OrderedItemListOperation]] = [:]
            tables.valueBox.begin()
            listTable.replaceItems(collectionId: 1, items: items, operations: &operations)
            tables.valueBox.commit()
            let rounds = 20
            var identicalOperations = 0
            var start = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< rounds {
                operations = [:]
                tables.valueBox.begin()
                listTable.replaceItems(collectionId: 1, items: items, operations: &operations)
                tables.valueBox.commit()
                identicalOperations += operations.count
            }
            let identical = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 / Double(rounds)
            start = CFAbsoluteTimeGetCurrent()
            for round in 0 ..< rounds {
                var changed = items
                changed[round] = self.entry(round, "changed \(round)")
                operations = [:]
                tables.valueBox.begin()
                listTable.replaceItems(collectionId: 1, items: changed, operations: &operations)
                tables.valueBox.commit()
            }
            let changed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 / Double(rounds)
            XCTAssertEqual(identicalOperations, 0)
            result = String(format: "identical list %.3f ms (no operation), one item changed %.3f ms", identical, changed)
        }
        NSLog("BENCHMARK ordered list replace of 300 items: %@", result)
    }

    // MARK: - Caches

    /// Benchmark (synthetic): 200 shared media of ~1 KB, each read 20 times, with and without
    /// the decoded-media cache. Logged as BENCHMARK.
    func testBenchmarkDecodedMediaCache() {
        let tables = MessageHistoryTableFixture(name: "PostboxRedundantWriteTests-mediabench")
        defer { tables.close() }
        let label = String(repeating: "m", count: 1000)
        var result: [String] = []
        tables.queue.sync {
            tables.valueBox.begin()
            let writer = MessageMediaTable(valueBox: tables.valueBox, table: tables.mediaTable.table, useCaches: false)
            for i in 0 ..< 200 {
                let _ = writer.set(FixtureMedia(id: MediaId(namespace: 1, id: Int64(i)), label: label), index: nil, messageHistoryTable: tables.messageHistoryTable)
            }
            for useCaches in [false, true] {
                let table = MessageMediaTable(valueBox: tables.valueBox, table: tables.mediaTable.table, useCaches: useCaches)
                var found = 0
                let start = CFAbsoluteTimeGetCurrent()
                for _ in 0 ..< 20 {
                    for i in 0 ..< 200 {
                        if table.get(MediaId(namespace: 1, id: Int64(i)), embedded: { _, _ in nil }) != nil {
                            found += 1
                        }
                    }
                }
                XCTAssertEqual(found, 4000)
                result.append(String(format: "%@ %.3f ms", useCaches ? "cached" : "uncached", (CFAbsoluteTimeGetCurrent() - start) * 1000.0))
            }
            tables.valueBox.commit()
        }
        NSLog("BENCHMARK 4000 media reads: %@", result.joined(separator: ", "))
    }

    func testBoundedValueCacheStaysWithinItsCapacity() {
        var cache = BoundedValueCache<Int, Int>(capacity: 10)
        for i in 0 ..< 1000 {
            cache.set(i, i)
            XCTAssertLessThanOrEqual(cache.count, 10)
            XCTAssertEqual(cache.get(i), i)
        }
        cache.remove(999)
        XCTAssertNil(cache.get(999))
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    /// Two table objects over one database stand for this process and another one.
    func testDecodedMediaFollowsWritesAndClearMemoryCache() {
        let tables = MessageHistoryTableFixture(name: "PostboxRedundantWriteTests-media")
        defer { tables.close() }
        let mediaId = MediaId(namespace: 1, id: 7)
        let label: (MessageMediaTable) -> String? = { table in
            return (table.get(mediaId, embedded: { _, _ in nil })?.1 as? FixtureMedia)?.label
        }
        tables.queue.sync {
            let local = MessageMediaTable(valueBox: tables.valueBox, table: tables.mediaTable.table, useCaches: true)
            let other = MessageMediaTable(valueBox: tables.valueBox, table: tables.mediaTable.table, useCaches: true)
            var operations: [PeerId: [MessageHistoryOperation]] = [:]
            tables.valueBox.begin()
            // A shared record: stored with no message index, it is a `Direct` entry.
            let _ = local.set(FixtureMedia(id: mediaId, label: "a"), index: nil, messageHistoryTable: tables.messageHistoryTable)
            XCTAssertEqual(label(local), "a")

            local.update(mediaId, media: FixtureMedia(id: mediaId, label: "b"), messageHistoryTable: tables.messageHistoryTable, operationsByPeerId: &operations)
            XCTAssertEqual(label(local), "b", "the table's own write drops the cached value")

            other.update(mediaId, media: FixtureMedia(id: mediaId, label: "c"), messageHistoryTable: tables.messageHistoryTable, operationsByPeerId: &operations)
            XCTAssertEqual(label(local), "b", "another process's write is not seen before the cache is cleared")
            local.clearMemoryCache()
            XCTAssertEqual(label(local), "c")

            let _ = local.removeReference(mediaId)
            let _ = local.removeReference(mediaId)
            XCTAssertNil(label(local), "the last reference removes the record")
            tables.valueBox.commit()
        }
    }

    /// Benchmark (synthetic): 200 forums' thread summaries, each read 20 times (a folder
    /// evaluates its filter per forum on every fill), with and without the cache.
    func testBenchmarkThreadSummaryCache() {
        let tables = MessageHistoryTableFixture(name: "PostboxRedundantWriteTests-threadbench")
        defer { tables.close() }
        guard let data = try? AdaptedPostboxEncoder().encode(StoredPeerThreadsSummary(totalUnreadCount: 3, hasUnmutedUnread: true, tagSummaries: [])) else {
            XCTFail("cannot encode")
            return
        }
        var result: [String] = []
        tables.queue.sync {
            tables.valueBox.begin()
            let spec = PeerThreadsSummaryTable.tableSpec(303)
            for i in 0 ..< 200 {
                let key = ValueBoxKey(length: 8)
                key.setInt64(0, value: self.peerId(Int64(1000 + i)).toInt64())
                tables.valueBox.set(spec, key: key, value: MemoryBuffer(data: data))
            }
            for useCaches in [false, true] {
                let table = PeerThreadsSummaryTable(valueBox: tables.valueBox, table: spec, useCaches: useCaches, seedConfiguration: tables.seedConfiguration)
                var found = 0
                let start = CFAbsoluteTimeGetCurrent()
                for _ in 0 ..< 20 {
                    for i in 0 ..< 200 {
                        if table.get(peerId: self.peerId(Int64(1000 + i))) != nil {
                            found += 1
                        }
                    }
                }
                XCTAssertEqual(found, 4000)
                result.append(String(format: "%@ %.3f ms", useCaches ? "cached" : "uncached", (CFAbsoluteTimeGetCurrent() - start) * 1000.0))
            }
            tables.valueBox.commit()
        }
        NSLog("BENCHMARK 4000 thread summary reads: %@", result.joined(separator: ", "))
    }

    func testThreadSummariesFollowClearMemoryCache() {
        let tables = MessageHistoryTableFixture(name: "PostboxRedundantWriteTests-threads")
        defer { tables.close() }
        let peerId = self.peerId(30)
        guard let data = try? AdaptedPostboxEncoder().encode(StoredPeerThreadsSummary(totalUnreadCount: 3, hasUnmutedUnread: true, tagSummaries: [])) else {
            XCTFail("cannot encode")
            return
        }
        tables.queue.sync {
            let summaries = PeerThreadsSummaryTable(valueBox: tables.valueBox, table: PeerThreadsSummaryTable.tableSpec(302), useCaches: true, seedConfiguration: tables.seedConfiguration)
            tables.valueBox.begin()
            XCTAssertNil(summaries.get(peerId: peerId))

            // Another process stores a summary for the peer.
            let key = ValueBoxKey(length: 8)
            key.setInt64(0, value: peerId.toInt64())
            tables.valueBox.set(summaries.table, key: key, value: MemoryBuffer(data: data))
            XCTAssertNil(summaries.get(peerId: peerId), "a missing summary is cached too")
            summaries.clearMemoryCache()
            XCTAssertEqual(summaries.get(peerId: peerId)?.totalUnreadCount, 3)
            tables.valueBox.commit()
        }
    }
}
