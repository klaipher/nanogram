import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// What one incoming message costs an open chat, with the read state applied as the app applies it while the
/// chat is visible (`ChatHistoryListNode.beginReadHistoryManagement` → TelegramCore
/// `_internal_applyMaxReadIndexInteractively` → `ManagedSynchronizePeerReadStates` pushing it):
///
/// 1. the update stores the message (one write transaction);
/// 2. the list sees it and applies the read mark (one write transaction: read state plus a `.Push` operation);
/// 3. the push reads the read state (read only), sends `readHistory` and confirms the operation (one write).
///
/// The second history update is the read mark itself: incoming entries never carry a read flag, but the view's
/// transient read state moves, and the list publishes it as the unread range the one-time effects of newly read
/// messages (animated emoji, stickers, transfers) use. It is not an echo. A view whose output does not depend on
/// read state (a comment thread, `MessageHistoryViewInput.external`) is another matter.
final class ReadStateEchoTests: XCTestCase {
    private var fixture: PostboxFixture!

    private let group = FixturePeer(id: MessageHistoryTableFixture.peerId(920), title: "group")
    private let namespace = PostboxFixture.messageNamespace

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "ReadStateEchoTests")
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func message(_ id: Int32, threadId: Int64? = nil) -> StoreMessage {
        return StoreMessage(id: MessageId(peerId: self.group.id, namespace: self.namespace, id: id), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: threadId, timestamp: 1000 + id, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil, text: "m\(id)", attributes: [], media: [])
    }

    private func index(_ id: Int32) -> MessageIndex {
        return MessageIndex(id: MessageId(peerId: self.group.id, namespace: self.namespace, id: id), timestamp: 1000 + id)
    }

    /// A chat with messages 1...5 (some in thread 100), all read, and no holes.
    private func seed(threadIds: [Int32: Int64] = [:]) {
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([self.group], update: { _, updated in updated })
            transaction.removeHole(peerId: self.group.id, threadId: nil, namespace: self.namespace, space: .everywhere, range: 1 ... (Int32.max - 1))
            for (_, threadId) in threadIds {
                transaction.removeHole(peerId: self.group.id, threadId: threadId, namespace: self.namespace, space: .everywhere, range: 1 ... (Int32.max - 1))
            }
            let _ = transaction.addMessages((1 ... 5).map { self.message($0, threadId: threadIds[$0]) }, location: .UpperHistoryBlock)
            transaction.resetIncomingReadStates([self.group.id: [self.namespace: .idBased(maxIncomingReadId: 5, maxOutgoingReadId: 0, maxKnownId: 5, count: 0, markedUnread: false)]])
        }
    }

    /// The three transactions the app runs for one incoming message read in the open chat.
    private func receiveAndRead(_ id: Int32, threadId: Int64? = nil) {
        self.fixture.transaction { transaction in
            let _ = transaction.addMessages([self.message(id, threadId: threadId)], location: .UpperHistoryBlock)
        }
        self.fixture.transaction { transaction in
            let _ = transaction.applyInteractiveReadMaxIndex(self.index(id))
        }
        // pushPeerReadState: reads the state, sends it, then confirms the operation.
        self.fixture.transaction { transaction in
            let _ = transaction.getPeerReadStates(self.group.id)
        }
        self.fixture.transaction { transaction in
            transaction.confirmSynchronizedIncomingReadState(self.group.id)
        }
    }

    private func maxIncomingReadId(_ view: MessageHistoryView) -> Int32? {
        guard case let .peer(states)? = view.transientReadStates, let state = states[self.group.id] else {
            return nil
        }
        for (namespace, value) in state.states where namespace == self.namespace {
            if case let .idBased(maxIncomingReadId, _, _, _, _) = value {
                return maxIncomingReadId
            }
        }
        return nil
    }

    // MARK: - Open chat

    func testIncomingMessageInOpenChatCostsTwoHistoryUpdatesAndTheSecondCarriesTheReadMark() {
        self.seed()
        let recorder = self.fixture.observeHistory(peerId: self.group.id, additionalData: [])
        recorder.waitForValues(count: 1)

        let messageCount = 5
        let updatesBefore = recorder.values.count
        let writesBefore = self.fixture.writeTransactionCount()
        for id in Int32(6) ..< Int32(6 + messageCount) {
            let before = recorder.values.count
            self.receiveAndRead(id)
            let values = recorder.values
            XCTAssertEqual(values.count - before, 2, "message \(id): stored, then read")
            guard values.count >= before + 2 else {
                continue
            }
            let stored = values[before]
            let read = values[before + 1]
            XCTAssertEqual(stored.entries.last?.message.id.id, id)
            XCTAssertEqual(self.maxIncomingReadId(stored), id - 1, "the store does not move the read mark")
            XCTAssertEqual(self.maxIncomingReadId(read), id, "the second update is the read mark")
            XCTAssertEqual(stored.entries.map(\.message.stableVersion), read.entries.map(\.message.stableVersion))
            XCTAssertEqual(stored.entries.map(\.isRead), read.entries.map(\.isRead), "incoming entries carry no read flag")
        }
        let updates = recorder.values.count - updatesBefore
        let writes = self.fixture.writeTransactionCount() - writesBefore
        NSLog("%@", "ReadStateEcho open chat: \(messageCount) messages, \(updates) history updates (\(Double(updates) / Double(messageCount)) per message), \(writes) write transactions (\(Double(writes) / Double(messageCount)) per message)")
        XCTAssertEqual(updates, 2 * messageCount)
        XCTAssertEqual(writes, Int64(3 * messageCount), "store, read, confirm; the push's read is not a write")
    }

    // MARK: - Comment thread

    /// A comment thread is an external view: its read marks come from the thread's input and its output carries no
    /// transient read state, so a read-state change of its group cannot change what it shows. It used to re-emit
    /// the whole view for every one, and the group's state moves with every incoming message in any of its
    /// threads (its unread count) and every read of it.
    func testCommentThreadViewIsNotReEmittedForItsGroupsReadState() {
        let threadId: Int64 = 100
        let otherThreadId: Int64 = 200
        self.seed(threadIds: [1: threadId, 2: threadId, 3: otherThreadId])
        let input = MessageHistoryViewExternalInput(content: .thread(peerId: self.group.id, id: threadId, holes: [:]), maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil)
        let recorder = self.fixture.observe(self.fixture.postbox.aroundMessageHistoryViewForLocation(.thread(peerId: self.group.id, threadId: threadId, data: .single(input)), anchor: .upperBound, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: [], count: 10, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tag: nil, appendMessagesFromTheSameGroup: false, namespaces: .all, orderStatistics: [], additionalData: []) |> map { $0.0 })
        let initial = recorder.waitForValues(count: 1).last!
        XCTAssertEqual(initial.entries.map { $0.message.id.id }, [1, 2])
        XCTAssertNil(initial.transientReadStates)

        // Messages arriving in another thread of the group, read in the group's own chat.
        for id in Int32(6) ... 10 {
            self.receiveAndRead(id, threadId: otherThreadId)
        }
        XCTAssertEqual(recorder.values.count, 1, "nothing the thread shows changed")

        // A message in the thread itself still updates it.
        self.fixture.transaction { transaction in
            let _ = transaction.addMessages([self.message(11, threadId: threadId)], location: .UpperHistoryBlock)
        }
        let values = recorder.waitForValues(count: 2)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.last?.entries.map { $0.message.id.id }, [1, 2, 11])
    }
}
