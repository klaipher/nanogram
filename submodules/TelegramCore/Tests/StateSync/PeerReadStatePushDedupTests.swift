import Foundation
import XCTest
import SwiftSignalKit
import Postbox
import TelegramApi
@testable import TelegramCore

/// The read-state sync sends a push once: two `Push` operations that differ only in what the server never sees (the top
/// known id, the outgoing read id, the unread count) make one `messages.readHistory`, and a push the server answered is
/// not repeated; a new maximum read id, or a push that was not answered, is still sent.
final class PeerReadStatePushDedupTests: StateSyncTestCase {
    private let readHistoryName = "messages.readHistory"
    private let getHistoryName = "messages.getHistory"
    private var syncDisposable: Disposable?

    override func tearDown() {
        self.syncDisposable?.dispose()
        self.syncDisposable = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func idBased(_ maxRead: Int32, known: Int32, count: Int32, outgoing: Int32 = 0, markedUnread: Bool = false) -> CombinedPeerReadState {
        return CombinedPeerReadState(states: [(Namespaces.Message.Cloud, .idBased(maxIncomingReadId: maxRead, maxOutgoingReadId: outgoing, maxKnownId: known, count: count, markedUnread: markedUnread))])
    }

    private func readHistoryCount() -> Int {
        return self.server.requests.filter({ $0.name == self.readHistoryName }).count
    }

    /// A private chat with messages `1 ... 5` stored, 2 of them unread (read mark 5 left over from a stale count), the
    /// state manager idle, the synchronizer running and every request it can send answered.
    private func startSynchronizer(userId: Int64) -> PeerId {
        let peer = self.seedUserChat(userId)
        for id in 1 ... 5 as ClosedRange<Int32> {
            self.fixture.storeMessage(peerId: peer, id: id, timestamp: self.baseDate + id, authorId: peer, text: "m\(id)")
        }
        self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 5, maxOutgoingReadId: 0, maxKnownId: 5, count: 2)
        self.launchIdle()
        self.server.always(self.readHistoryName, { _ in
            return .result(Api.messages.AffectedMessages.affectedMessages(.init(pts: 100, ptsCount: 0)))
        })
        self.server.always(self.getHistoryName, { _ in
            return .result(StateSyncApi.messages([StateSyncApi.privateMessage(id: 5, peerUserId: userId, fromUserId: userId, date: Int32(clamping: Int64(self.baseDate) + 5))]))
        })
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in
            return .result(StateSyncApi.peerDialogs(dialogs: [StateSyncApi.dialog(peer: StateSyncApi.peerUser(userId), topMessage: 5, readInboxMaxId: 5, unreadCount: 0)], state: StateSyncApi.state(pts: 100, qts: 5, date: self.baseDate, seq: 10)))
        })
        self.syncDisposable = managedSynchronizePeerReadStates(network: self.network, postbox: self.fixture.postbox, stateManager: self.stateManager).start()
        return peer
    }

    private func readInteractively(_ peer: PeerId, upTo id: Int32) {
        self.fixture.transaction { transaction -> Void in
            let _ = transaction.applyInteractiveReadMaxIndex(MessageIndex(id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: id), timestamp: self.baseDate + id))
        }
    }

    private func waitUntilSynchronized(_ peer: PeerId) {
        self.fixture.eventually {
            let operation = self.fixture.wait(self.fixture.postbox.synchronizePeerReadStatesView() |> map { $0.operations[peer] }) ?? nil
            return operation == nil
        }
        self.drainOperationQueue()
    }

    // MARK: - Payload

    func testPushesDifferingOnlyInLocalBookkeepingHaveTheSamePayload() {
        let a = PeerReadStateSynchronizationOperation.Push(state: self.idBased(5, known: 5, count: 0), thenSync: false)
        let b = PeerReadStateSynchronizationOperation.Push(state: self.idBased(5, known: 9, count: 4, outgoing: 3), thenSync: false)
        XCTAssertEqual(a.syncPayload, b.syncPayload)
        XCTAssertNotEqual(a, b)
    }

    func testPushesDifferingInWhatIsSentHaveDifferentPayloads() {
        let base = PeerReadStateSynchronizationOperation.Push(state: self.idBased(5, known: 5, count: 0), thenSync: false)
        XCTAssertNotEqual(base.syncPayload, PeerReadStateSynchronizationOperation.Push(state: self.idBased(6, known: 6, count: 0), thenSync: false).syncPayload)
        XCTAssertNotEqual(base.syncPayload, PeerReadStateSynchronizationOperation.Push(state: self.idBased(5, known: 5, count: 0, markedUnread: true), thenSync: false).syncPayload)
        XCTAssertNotEqual(base.syncPayload, PeerReadStateSynchronizationOperation.Push(state: self.idBased(5, known: 5, count: 0), thenSync: true).syncPayload)
        XCTAssertNotEqual(base.syncPayload, PeerReadStateSynchronizationOperation.Validate.syncPayload)
    }

    // MARK: - Ledger

    func testLedgerDropsAPushTheServerDisagreesWith() {
        let ledger = PeerReadStatePushLedger()
        let peer = StateSyncFixture.userPeerId(2100)
        let payload = PeerReadStatePushLedger.Payload(maxIncomingReadId: 5, markedUnread: false)
        ledger.record(peerId: peer, payload: payload, generation: ledger.generation(peerId: peer))
        XCTAssertEqual(ledger.lastPush(peerId: peer), payload)

        ledger.note(peerId: peer, serverMaxIncomingReadId: 5, serverMarkedUnread: false)
        XCTAssertEqual(ledger.lastPush(peerId: peer), payload, "the server agrees")
        ledger.note(peerId: peer, serverMaxIncomingReadId: 9, serverMarkedUnread: false)
        XCTAssertEqual(ledger.lastPush(peerId: peer), payload, "the server is ahead")
        ledger.note(peerId: peer, serverMaxIncomingReadId: nil, serverMarkedUnread: true)
        XCTAssertNil(ledger.lastPush(peerId: peer), "another device marked the chat unread")

        ledger.record(peerId: peer, payload: payload, generation: ledger.generation(peerId: peer))
        ledger.note(peerId: peer, serverMaxIncomingReadId: 3, serverMarkedUnread: false)
        XCTAssertNil(ledger.lastPush(peerId: peer), "the server is behind")
    }

    func testLedgerIgnoresAPushThatWasInFlightWhenTheServerReported() {
        let ledger = PeerReadStatePushLedger()
        let peer = StateSyncFixture.userPeerId(2101)
        let generation = ledger.generation(peerId: peer)
        ledger.note(peerId: peer, serverMaxIncomingReadId: 2, serverMarkedUnread: true)
        ledger.record(peerId: peer, payload: PeerReadStatePushLedger.Payload(maxIncomingReadId: 5, markedUnread: false), generation: generation)
        XCTAssertNil(ledger.lastPush(peerId: peer))
    }

    // MARK: - Scripted

    /// Two pushes of the same read mark whose read states differ in the top known id and the unread count: one request.
    func testTwoPushesDifferingOnlyInTopKnownIdAndCountSendOneReadHistory() {
        let peer = self.startSynchronizer(userId: 2001)

        self.readInteractively(peer, upTo: 5)
        self.waitUntilSynchronized(peer)
        XCTAssertEqual(self.readHistoryCount(), 1)

        // Same read mark, other top known id and count.
        self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 5, maxOutgoingReadId: 0, maxKnownId: 6, count: 3)
        self.readInteractively(peer, upTo: 5)
        self.waitUntilSynchronized(peer)

        XCTAssertEqual(self.readHistoryCount(), 1, "requests: \(self.server.requestNames)")
    }

    /// A read mark above the pushed one is pushed.
    func testANewMaxReadIdIsStillPushed() {
        let peer = self.startSynchronizer(userId: 2002)

        self.readInteractively(peer, upTo: 5)
        self.waitUntilSynchronized(peer)
        XCTAssertEqual(self.readHistoryCount(), 1)

        for id in 6 ... 7 as ClosedRange<Int32> {
            self.fixture.storeMessage(peerId: peer, id: id, timestamp: self.baseDate + id, authorId: peer, text: "m\(id)")
        }
        self.readInteractively(peer, upTo: 7)
        self.waitUntilSynchronized(peer)

        let reads = self.server.requests.filter({ $0.name == self.readHistoryName })
        XCTAssertEqual(reads.count, 2, "requests: \(self.server.requestNames)")
        let expected = Api.functions.messages.readHistory(peer: .inputPeerUser(.init(userId: peer.id._internalGetInt64Value(), accessHash: 1)), maxId: 7).1.makeData()
        XCTAssertEqual(reads.last?.payload, expected)
    }

    /// A push the server did not answer is not remembered: the same mark is sent again.
    func testAPushTheServerRejectedIsSentAgain() {
        let peer = self.seedUserChat(2003)
        for id in 1 ... 5 as ClosedRange<Int32> {
            self.fixture.storeMessage(peerId: peer, id: id, timestamp: self.baseDate + id, authorId: peer, text: "m\(id)")
        }
        self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 5, maxOutgoingReadId: 0, maxKnownId: 5, count: 2)
        self.launchIdle()
        self.server.on(self.readHistoryName, .error(code: 400, text: "MESSAGE_ID_INVALID"))
        self.server.always(self.readHistoryName, { _ in
            return .result(Api.messages.AffectedMessages.affectedMessages(.init(pts: 100, ptsCount: 0)))
        })
        self.server.always(self.getHistoryName, { _ in
            return .result(StateSyncApi.messages([StateSyncApi.privateMessage(id: 5, peerUserId: 2003, fromUserId: 2003, date: Int32(clamping: Int64(self.baseDate) + 5))]))
        })
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in
            return .result(StateSyncApi.peerDialogs(dialogs: [StateSyncApi.dialog(peer: StateSyncApi.peerUser(2003), topMessage: 5, readInboxMaxId: 5, unreadCount: 0)], state: StateSyncApi.state(pts: 100, qts: 5, date: self.baseDate, seq: 10)))
        })
        self.syncDisposable = managedSynchronizePeerReadStates(network: self.network, postbox: self.fixture.postbox, stateManager: self.stateManager).start()

        self.readInteractively(peer, upTo: 5)
        self.waitUntilSynchronized(peer)
        XCTAssertEqual(self.readHistoryCount(), 1)

        self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 5, maxOutgoingReadId: 0, maxKnownId: 6, count: 3)
        self.readInteractively(peer, upTo: 5)
        self.waitUntilSynchronized(peer)

        XCTAssertEqual(self.readHistoryCount(), 2, "requests: \(self.server.requestNames)")
    }
}
