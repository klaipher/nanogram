import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// Notification settings that only say whether the chat is muted.
final class FixtureNotificationSettings: PeerNotificationSettings {
    static let register: Void = {
        declareEncodable(FixtureNotificationSettings.self, f: { FixtureNotificationSettings(decoder: $0) })
    }()

    let isMuted: Bool

    init(isMuted: Bool) {
        self.isMuted = isMuted
    }

    init(decoder: PostboxDecoder) {
        self.isMuted = decoder.decodeBoolForKey("m", orElse: false)
    }

    func encode(_ encoder: PostboxEncoder) {
        encoder.encodeBool(self.isMuted, forKey: "m")
    }

    func isRemovedFromTotalUnreadCount(default: Bool) -> Bool {
        return self.isMuted
    }

    var behavior: PeerNotificationSettingsBehavior {
        return .none
    }

    func isEqual(to other: PeerNotificationSettings) -> Bool {
        return (other as? FixtureNotificationSettings)?.isMuted == self.isMuted
    }
}

/// Deterministic generator, so a failing seed can be replayed.
struct FixtureRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E3779B97F4A7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upperBound: Int) -> Int {
        return Int(truncatingIfNeeded: self.next() % UInt64(truncatingIfNeeded: max(upperBound, 1)))
    }

    mutating func bool() -> Bool {
        return self.next() & 1 == 1
    }
}

/// A chat list space used to re-query the table on every transaction (`if true ||
/// hadRemovals`). It now skips a direction the last fill found exhausted until something
/// the fill depends on changes. These tests run views in the old mode next to views in the
/// new mode over random transactions and require identical output after each one.
final class ChatListViewFillSkipTests: XCTestCase {
    private var fixture: PostboxFixture!
    private let namespace = PostboxFixture.messageNamespace
    private let archive = PeerGroupId(rawValue: 1)

    override func setUp() {
        super.setUp()
        let _ = FixtureNotificationSettings.register
        self.fixture = PostboxFixture(name: "ChatListViewFillSkipTests")
    }

    override func tearDown() {
        ChatListViewTestHooks.alwaysRefillSpaces = false
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func peerId(_ i: Int) -> PeerId {
        return MessageHistoryTableFixture.peerId(Int64(5000 + i))
    }

    private func message(peerId: PeerId, id: Int32, timestamp: Int32, text: String = "") -> StoreMessage {
        return MessageHistoryTableFixture.storeMessage(id: MessageId(peerId: peerId, namespace: self.namespace, id: id), timestamp: timestamp, text: text, flags: [.Incoming])
    }

    /// A folder whose result depends on every input the predicate is given.
    private func folderPredicate(pinned: [PeerId] = [], include: Set<PeerId> = [], exclude: Set<PeerId> = [], archive: Bool) -> ChatListFilterPredicate {
        return ChatListFilterPredicate(includePeerIds: include, excludePeerIds: exclude, pinnedPeerIds: pinned, messageTagSummary: nil, includeAdditionalPeerGroupIds: archive ? [self.archive] : [], include: { peer, isRemovedFromTotalUnreadCount, isUnread, isContact, _ in
            let title = (peer as? FixturePeer)?.title ?? ""
            if title.hasSuffix("x") {
                return false
            }
            if isRemovedFromTotalUnreadCount && !isUnread {
                return false
            }
            if isContact {
                return true
            }
            return isUnread || title.count % 3 == 0
        })
    }

    private struct ViewPair {
        let name: String
        let legacy: PostboxFixture.Recorder<ChatListView>
        let current: PostboxFixture.Recorder<ChatListView>
    }

    private func observePair(_ name: String, _ make: () -> Signal<(ChatListView, ViewUpdateType), NoError>) -> ViewPair {
        ChatListViewTestHooks.alwaysRefillSpaces = true
        let legacy = self.fixture.observe(make() |> map { $0.0 })
        legacy.waitForValues(count: 1)
        ChatListViewTestHooks.alwaysRefillSpaces = false
        let current = self.fixture.observe(make() |> map { $0.0 })
        current.waitForValues(count: 1)
        return ViewPair(name: name, legacy: legacy, current: current)
    }

    private func describe(_ view: ChatListView?) -> String {
        guard let view = view else {
            return "nil"
        }
        let entries = view.entries.map { entry -> String in
            switch entry {
            case let .MessageEntry(data):
                return "\(data.index.messageIndex.id.peerId.id._internalGetInt64Value())@\(data.index.messageIndex.timestamp)\(data.index.pinningIndex.map { "p\($0)" } ?? "")"
            case let .HoleEntry(hole):
                return "hole@\(hole.index.timestamp)"
            }
        }
        return "[\(entries.joined(separator: ", "))] earlier: \(String(describing: view.earlierIndex)) later: \(String(describing: view.laterIndex))"
    }

    private func assertSame(_ pairs: [ViewPair], step: String, file: StaticString = #file, line: UInt = #line) -> Bool {
        var same = true
        for pair in pairs {
            let legacy = pair.legacy.values.last
            let current = pair.current.values.last
            if legacy?.entries != current?.entries || legacy?.earlierIndex != current?.earlierIndex || legacy?.laterIndex != current?.laterIndex {
                XCTFail("\(pair.name) differs after \(step)\nold: \(self.describe(legacy))\nnew: \(self.describe(current))", file: file, line: line)
                same = false
            }
        }
        return same
    }

    // MARK: - Equivalence

    func testRandomTransactionsGiveTheSameViewsAsRefillingEveryTime() {
        for seed: UInt64 in [1, 2, 3, 4] {
            if !self.runRandomTransactions(seed: seed, count: 250) {
                break
            }
            self.fixture.close()
            self.fixture = PostboxFixture(name: "ChatListViewFillSkipTests")
        }
    }

    /// Returns false after the first mismatch so one bad seed reports once.
    private func runRandomTransactions(seed: UInt64, count: Int) -> Bool {
        var random = FixtureRandom(seed: seed)
        let peerCount = 36
        var nextMessageId: [PeerId: Int32] = [:]
        var messageIds: [PeerId: [Int32]] = [:]
        var timestamp: Int32 = 10_000
        var titleVersion: [PeerId: Int] = [:]

        func title(_ peerId: PeerId, _ version: Int) -> String {
            return "c\(peerId.id._internalGetInt64Value() % 100)-\(version)" + (version % 4 == 3 ? "x" : "")
        }

        // Seed: chats in the main list and the archive, some with several messages.
        self.fixture.transaction { transaction in
            var peers: [Peer] = []
            for i in 0 ..< peerCount {
                let peerId = self.peerId(i)
                titleVersion[peerId] = i % 5
                peers.append(FixturePeer(id: peerId, title: title(peerId, i % 5), isForum: i % 9 == 8))
            }
            transaction.updatePeersInternal(peers, update: { _, updated in updated })
            for i in 0 ..< peerCount {
                let peerId = self.peerId(i)
                transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: i % 6 == 5 ? self.archive : .root, pinningIndex: nil, minTimestamp: nil))
                var stored: [StoreMessage] = []
                for _ in 0 ..< 1 + i % 3 {
                    let id = (nextMessageId[peerId] ?? 0) + 1
                    nextMessageId[peerId] = id
                    messageIds[peerId, default: []].append(id)
                    timestamp += Int32(truncatingIfNeeded: 1 + random.int(20))
                    stored.append(self.message(peerId: peerId, id: id, timestamp: timestamp))
                }
                let _ = transaction.addMessages(stored, location: .Random)
                if i % 4 == 0 {
                    transaction.resetIncomingReadStates([peerId: [self.namespace: .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 10, count: 2, markedUnread: false)]])
                }
            }
            transaction.setPinnedItemIds(groupId: .root, itemIds: [.peer(self.peerId(1)), .peer(self.peerId(7))])
            transaction.replaceContactPeerIds(Set([self.peerId(2), self.peerId(3), self.peerId(11)]))
        }

        let middle = ChatListIndex(pinningIndex: nil, messageIndex: MessageIndex(id: MessageId(peerId: self.peerId(0), namespace: self.namespace, id: 1), timestamp: Int32(clamping: Int64(timestamp) - 300)))
        let summary = ChatListEntrySummaryComponents()
        guard let postbox = self.fixture.postbox else {
            XCTFail("no postbox")
            return false
        }
        let pairs: [ViewPair] = [
            self.observePair("main list", { postbox.tailChatListView(groupId: .root, count: 8, summaryComponents: summary) }),
            self.observePair("main list, middle", { postbox.aroundChatListView(groupId: .root, index: middle, count: 6, summaryComponents: summary) }),
            self.observePair("archive", { postbox.tailChatListView(groupId: self.archive, count: 8, summaryComponents: summary) }),
            self.observePair("folder", { postbox.tailChatListView(groupId: .root, filterPredicate: self.folderPredicate(pinned: [self.peerId(4), self.peerId(1)], archive: true), count: 6, summaryComponents: summary) }),
            self.observePair("large folder", { postbox.tailChatListView(groupId: .root, filterPredicate: self.folderPredicate(include: [self.peerId(5)], exclude: [self.peerId(6)], archive: false), count: 40, summaryComponents: summary) }),
            self.observePair("folder, middle", { postbox.aroundChatListView(groupId: .root, filterPredicate: self.folderPredicate(archive: true), index: middle, count: 5, summaryComponents: summary) }),
        ]
        if !self.assertSame(pairs, step: "seed \(seed) start") {
            return false
        }

        var hidden: [PeerId: Int] = [:]
        for step in 0 ..< count {
            var described: [String] = []
            self.fixture.transaction { transaction in
                for _ in 0 ..< 1 + random.int(2) {
                    let peerId = self.peerId(random.int(peerCount))
                    switch random.int(17) {
                    case 0, 1:
                        let id = (nextMessageId[peerId] ?? 0) + 1
                        nextMessageId[peerId] = id
                        messageIds[peerId, default: []].append(id)
                        timestamp += Int32(truncatingIfNeeded: 1 + random.int(30))
                        let _ = transaction.addMessages([self.message(peerId: peerId, id: id, timestamp: timestamp)], location: .Random)
                        described.append("message \(peerId.id)")
                    case 2:
                        if let id = messageIds[peerId]?.popLast() {
                            transaction.deleteMessages([MessageId(peerId: peerId, namespace: self.namespace, id: id)], forEachMedia: nil)
                            described.append("delete \(peerId.id)")
                        }
                    case 3:
                        // An edit keeps the chat's index: removed and inserted in place.
                        if let id = messageIds[peerId]?.last {
                            let text = "edit \(random.next())"
                            transaction.updateMessage(MessageId(peerId: peerId, namespace: self.namespace, id: id), update: { current in
                                return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: nil, authorId: nil, text: text, attributes: [], media: []))
                            })
                            described.append("edit \(peerId.id)")
                        }
                    case 4:
                        let version = (titleVersion[peerId] ?? 0) + 1
                        titleVersion[peerId] = version
                        transaction.updatePeersInternal([FixturePeer(id: peerId, title: title(peerId, version), isForum: peerId.id._internalGetInt64Value() % 9 == 8)], update: { _, updated in updated })
                        described.append("rename \(peerId.id)")
                    case 5:
                        let unread = random.bool()
                        transaction.resetIncomingReadStates([peerId: [self.namespace: .idBased(maxIncomingReadId: unread ? 0 : 10, maxOutgoingReadId: 0, maxKnownId: 10, count: unread ? 3 : 0, markedUnread: false)]])
                        described.append("read state \(peerId.id) \(unread)")
                    case 6:
                        transaction.applyMarkUnread(peerId: peerId, namespace: self.namespace, value: random.bool(), interactive: false)
                        described.append("mark unread \(peerId.id)")
                    case 7:
                        transaction.updateCurrentPeerNotificationSettings([peerId: FixtureNotificationSettings(isMuted: random.bool())])
                        described.append("mute \(peerId.id)")
                    case 8:
                        var contacts = Set<PeerId>()
                        for _ in 0 ..< random.int(6) {
                            contacts.insert(self.peerId(random.int(peerCount)))
                        }
                        transaction.replaceContactPeerIds(contacts)
                        described.append("contacts")
                    case 9:
                        transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in FixtureCachedPeerData(peerIds: [self.peerId(random.int(peerCount))]) })
                        described.append("cached data \(peerId.id)")
                    case 10:
                        if let index = hidden.removeValue(forKey: peerId) {
                            transaction.removeChatHidden(peerId: peerId, index: index)
                            described.append("unhide \(peerId.id)")
                        } else {
                            hidden[peerId] = transaction.addChatHidden(peerId: peerId)
                            described.append("hide \(peerId.id)")
                        }
                    case 11:
                        // A draft: a newer override timestamp moves the chat, a text-only one does not.
                        let override: Int32? = random.bool() ? Int32(clamping: Int64(timestamp) + Int64(random.int(50))) : nil
                        transaction.setPeerChatInterfaceState(peerId, state: StoredPeerChatInterfaceState(overrideChatTimestamp: override, historyScrollMessageIndex: nil, associatedMessageIds: [], data: Data([UInt8(truncatingIfNeeded: random.next())])))
                        described.append("draft \(peerId.id)")
                    case 12:
                        var pinned: [PinnedItemId] = []
                        for _ in 0 ..< random.int(4) {
                            let item = PinnedItemId.peer(self.peerId(random.int(peerCount)))
                            if !pinned.contains(item) {
                                pinned.append(item)
                            }
                        }
                        transaction.setPinnedItemIds(groupId: .root, itemIds: pinned)
                        described.append("pin \(pinned.count)")
                    case 13:
                        // Not the folder's pinned chats: a move between groups reaches their
                        // space as an insert into one group and a removal from the other,
                        // in dictionary order, and an insert that comes first trips the
                        // existing-index assertion in add() (old behaviour, unchanged).
                        if peerId == self.peerId(1) || peerId == self.peerId(4) {
                            break
                        }
                        let groupId: PeerGroupId = random.bool() ? self.archive : .root
                        transaction.updatePeerChatListInclusion(peerId, inclusion: random.int(5) == 0 ? .notIncluded : .ifHasMessagesOrOneOf(groupId: groupId, pinningIndex: nil, minTimestamp: nil))
                        described.append("move \(peerId.id) \(groupId.rawValue)")
                    case 14:
                        transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: 1, key: ValueBoxKey(length: 8)), entry: CodableEntry(data: Data([UInt8(truncatingIfNeeded: random.next())])))
                        described.append("item cache")
                    case 15:
                        transaction.setPreferencesEntry(key: ValueBoxKey("p\(random.int(3))"), value: PreferencesEntry(data: Data([UInt8(truncatingIfNeeded: random.next())])))
                        described.append("preferences")
                    default:
                        transaction.applyIncomingReadMaxId(MessageId(peerId: peerId, namespace: self.namespace, id: nextMessageId[peerId] ?? 1))
                        described.append("read \(peerId.id)")
                    }
                }
            }
            // A barrier: views have been replayed when an empty transaction completes.
            self.fixture.transaction { _ in }
            if !self.assertSame(pairs, step: "seed \(seed) step \(step): \(described.joined(separator: "; "))") {
                return false
            }
        }
        return true
    }

    // MARK: - The skip itself

    /// Chats 0 (oldest) to `chats - 1`. The folder below matches one chat in ten among the
    /// newer half only, so a fill below its oldest row scans the older half to the end.
    private func seedLargeList(chats: Int) {
        self.fixture.transaction { transaction in
            var peers: [Peer] = []
            for i in 0 ..< chats {
                let matches = i >= chats / 2 && i % 10 == 5
                peers.append(FixturePeer(id: self.peerId(i), title: "c\(i)" + (matches ? "" : "x")))
            }
            transaction.updatePeersInternal(peers, update: { _, updated in updated })
            for i in 0 ..< chats {
                let peerId = self.peerId(i)
                transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
                let _ = transaction.addMessages([self.message(peerId: peerId, id: 1, timestamp: Int32(clamping: 1000 + i))], location: .Random)
            }
        }
    }

    /// A folder that matches few chats never fills its 50 rows.
    private func sparseFolder() -> ChatListFilterPredicate {
        return ChatListFilterPredicate(includePeerIds: [], excludePeerIds: [], pinnedPeerIds: [], messageTagSummary: nil, includeAdditionalPeerGroupIds: [], include: { peer, _, _, _, _ in
            return !((peer as? FixturePeer)?.title ?? "").hasSuffix("x")
        })
    }

    func testAnUnrelatedTransactionDoesNotQueryAnExhaustedFolder() {
        self.seedLargeList(chats: 200)
        let recorder = self.fixture.observe(self.fixture.postbox.tailChatListView(groupId: .root, filterPredicate: self.sparseFolder(), count: 50, summaryComponents: ChatListEntrySummaryComponents()) |> map { $0.0 })
        XCTAssertEqual(recorder.waitForValues(count: 1).last?.entries.count, 10)

        var queries = ChatListViewFillCounters.queries
        self.fixture.transaction { transaction in
            transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: 1, key: ValueBoxKey(length: 8)), entry: CodableEntry(data: Data([1])))
        }
        XCTAssertEqual(ChatListViewFillCounters.queries, queries, "nothing the folder reads changed")

        // A message edit removes and re-inserts the chat at the same index.
        self.fixture.transaction { transaction in
            transaction.updateMessage(MessageId(peerId: self.peerId(30), namespace: self.namespace, id: 1), update: { current in
                return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: nil, authorId: nil, text: "edited", attributes: [], media: []))
            })
        }
        XCTAssertEqual(ChatListViewFillCounters.queries, queries, "an edit keeps the chat where it was")

        // A rename is an input of the filter, so the folder is filled again.
        queries = ChatListViewFillCounters.queries
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: self.peerId(31), title: "c31")], update: { _, updated in updated })
        }
        XCTAssertGreaterThan(ChatListViewFillCounters.queries, queries)
    }

    /// Benchmark (synthetic): 2000 chats, a folder with 100 of the newer ones, 200
    /// transactions that touch nothing the folder reads. Logs the time per transaction in
    /// both modes.
    func testBenchmarkUnrelatedTransactionsWithAnOpenFolder() {
        var results: [String] = []
        for legacy in [true, false] {
            // A fresh database per mode, so only one folder view is open at a time.
            if !legacy {
                self.fixture.close()
                self.fixture = PostboxFixture(name: "ChatListViewFillSkipTests")
            }
            self.seedLargeList(chats: 2000)
            ChatListViewTestHooks.alwaysRefillSpaces = legacy
            let recorder = self.fixture.observe(self.fixture.postbox.tailChatListView(groupId: .root, filterPredicate: self.sparseFolder(), count: 150, summaryComponents: ChatListEntrySummaryComponents()) |> map { $0.0 })
            recorder.waitForValues(count: 1)
            ChatListViewTestHooks.alwaysRefillSpaces = false
            let queries = ChatListViewFillCounters.queries
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0 ..< 200 {
                self.fixture.transaction { transaction in
                    transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: 1, key: ValueBoxKey(length: 8)), entry: CodableEntry(data: Data([UInt8(truncatingIfNeeded: i)])))
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            results.append("\(legacy ? "refill every time" : "exhausted flags"): \(String(format: "%.3f", elapsed * 1000.0 / 200.0)) ms per transaction, \(ChatListViewFillCounters.queries - queries) fill queries")
        }
        NSLog("BENCHMARK chat list fill: %@", results.joined(separator: "; "))
    }
}
