import Foundation
import XCTest
import SwiftSignalKit
import Postbox
import TelegramApi
@testable import TelegramCore

/// A read-state operation that fails runs again after a growing delay (`peerReadStateSyncRetryDelay`), not at once:
/// while the server's read mark stays behind the local one, validation asks to retry, and upstream then sent one
/// `messages.getPeerDialogs` per round trip until something changed. An operation with another payload (a new read
/// mark) does not wait, and a completed operation starts the count again. A retry also sends a pushed read mark again
/// instead of taking it as accepted.
final class PeerReadStateRetryBackoffTests: StateSyncTestCase {
    private let readHistoryName = "messages.readHistory"
    private let getHistoryName = "messages.getHistory"
    private var syncDisposable: Disposable?

    override func tearDown() {
        self.syncDisposable?.dispose()
        self.syncDisposable = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func count(_ name: String) -> Int {
        return self.server.requests.filter({ $0.name == name }).count
    }

    /// The server's dialog with its read mark at 3 and 2 messages unread: behind a local mark of 5, so validation retries.
    private func behindAnswer(userId: Int64) -> ScriptedAnswer {
        return .result(StateSyncApi.peerDialogs(dialogs: [StateSyncApi.dialog(peer: StateSyncApi.peerUser(userId), topMessage: 5, readInboxMaxId: 3, unreadCount: 2)], state: StateSyncApi.state(pts: 100, qts: 5, date: self.baseDate, seq: 10)))
    }

    private func caughtUpAnswer(userId: Int64) -> ScriptedAnswer {
        return .result(StateSyncApi.peerDialogs(dialogs: [StateSyncApi.dialog(peer: StateSyncApi.peerUser(userId), topMessage: 5, readInboxMaxId: 5, unreadCount: 0)], state: StateSyncApi.state(pts: 100, qts: 5, date: self.baseDate, seq: 10)))
    }

    /// A private chat with messages `1 ... 5` stored and read up to 5 here, the state manager idle, and every request
    /// but `getPeerDialogs` answered.
    private func setUpChat(userId: Int64) -> PeerId {
        let peer = self.seedUserChat(userId)
        for id in 1 ... 5 as ClosedRange<Int32> {
            self.fixture.storeMessage(peerId: peer, id: id, timestamp: self.baseDate + id, authorId: peer, text: "m\(id)")
        }
        self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 5, maxOutgoingReadId: 0, maxKnownId: 5, count: 0)
        self.launchIdle()
        self.server.always(self.readHistoryName, { _ in
            return .result(Api.messages.AffectedMessages.affectedMessages(.init(pts: 100, ptsCount: 0)))
        })
        self.server.always(self.getHistoryName, { _ in
            return .result(StateSyncApi.messages([StateSyncApi.privateMessage(id: 5, peerUserId: userId, fromUserId: userId, date: Int32(clamping: Int64(self.baseDate) + 5))]))
        })
        return peer
    }

    private func queueValidation(_ peer: PeerId) {
        self.fixture.transaction { transaction -> Void in
            transaction.setNeedsIncomingReadStateSynchronization(peer)
        }
    }

    /// Starts the synchronizer with `delay` as its retry delay; the returned list holds the attempt of every retry it
    /// scheduled, in order.
    private func startSynchronizer(delay: Double) -> Atomic<[Int]> {
        let attempts = Atomic<[Int]>(value: [])
        self.syncDisposable = managedSynchronizePeerReadStates(network: self.network, postbox: self.fixture.postbox, stateManager: self.stateManager, retryDelay: { attempt in
            let _ = attempts.modify { $0 + [attempt] }
            return delay
        }).start()
        return attempts
    }

    private func pendingOperation(_ peer: PeerId) -> PeerReadStateSynchronizationOperation? {
        return self.fixture.wait(self.fixture.postbox.synchronizePeerReadStatesView() |> map { $0.operations[peer] }) ?? nil
    }

    private func waitUntilSynchronized(_ peer: PeerId) {
        self.fixture.eventually {
            return self.pendingOperation(peer) == nil
        }
        self.drainOperationQueue()
    }

    // MARK: - Delay

    func testRetryDelayDoublesFromOneSecondUpToThirty() {
        XCTAssertEqual((0 ... 8).map { peerReadStateSyncRetryDelay(attempt: $0) }, [1.0, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0])
        XCTAssertEqual(peerReadStateSyncRetryDelay(attempt: Int.max), 30.0)
    }

    // MARK: - Scripted

    /// The server stays behind: one `getPeerDialogs`, then nothing while the retry waits, and the operation is kept.
    func testAValidationTheServerIsBehindWaitsBeforeAskingAgain() {
        let peer = self.setUpChat(userId: 2301)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.behindAnswer(userId: 2301) })
        self.queueValidation(peer)
        let attempts = self.startSynchronizer(delay: 60.0)

        self.fixture.eventually {
            return attempts.with { $0.count } == 1
        }
        Thread.sleep(forTimeInterval: 1.0)
        self.server.flush()

        XCTAssertEqual(self.count(StateSyncRequestName.getPeerDialogs), 1, "requests: \(self.server.requestNames)")
        XCTAssertEqual(attempts.with { $0 }, [1])
        XCTAssertEqual(self.pendingOperation(peer), .Validate, "a retry is never given up")
    }

    /// The server stays behind: the operation keeps running, each retry one attempt further along the backoff.
    func testRetriesContinueWithAGrowingAttempt() {
        let peer = self.setUpChat(userId: 2302)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.behindAnswer(userId: 2302) })
        self.queueValidation(peer)
        let attempts = self.startSynchronizer(delay: 0.2)

        self.fixture.eventually {
            return attempts.with { $0.count } >= 3
        }

        let recorded = attempts.with { $0 }
        XCTAssertEqual(recorded, recorded.enumerated().map { $0.offset + 1 })
        XCTAssertLessThanOrEqual(self.count(StateSyncRequestName.getPeerDialogs), recorded.count + 1)
    }

    /// A new read mark during the wait is pushed at once.
    func testANewReadMarkDuringTheWaitStartsAtOnce() {
        let peer = self.setUpChat(userId: 2303)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.behindAnswer(userId: 2303) })
        self.queueValidation(peer)
        let attempts = self.startSynchronizer(delay: 60.0)
        self.fixture.eventually {
            return attempts.with { $0.count } == 1
        }
        XCTAssertEqual(self.count(self.readHistoryName), 0)

        for id in 6 ... 7 as ClosedRange<Int32> {
            self.fixture.storeMessage(peerId: peer, id: id, timestamp: self.baseDate + id, authorId: peer, text: "m\(id)")
        }
        self.fixture.transaction { transaction -> Void in
            let _ = transaction.applyInteractiveReadMaxIndex(MessageIndex(id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 7), timestamp: Int32(clamping: Int64(self.baseDate) + 7)))
        }

        self.fixture.eventually(timeout: 5.0) {
            return self.count(self.readHistoryName) == 1
        }
    }

    /// A completed operation starts the backoff over: the next failure waits as long as the first one did.
    func testCompletionResetsTheAttempt() {
        let peer = self.setUpChat(userId: 2304)
        self.server.on(StateSyncRequestName.getPeerDialogs, self.behindAnswer(userId: 2304))
        self.server.on(StateSyncRequestName.getPeerDialogs, self.behindAnswer(userId: 2304))
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.caughtUpAnswer(userId: 2304) })
        self.queueValidation(peer)
        let attempts = self.startSynchronizer(delay: 0.1)
        self.waitUntilSynchronized(peer)
        XCTAssertEqual(attempts.with { $0 }, [1, 2])

        self.server.on(StateSyncRequestName.getPeerDialogs, self.behindAnswer(userId: 2304))
        self.queueValidation(peer)
        self.waitUntilSynchronized(peer)

        XCTAssertEqual(attempts.with { $0 }, [1, 2, 1])
    }

    // MARK: - Ledger

    /// A push the server answered, then a validation that finds the server behind it: the retry sends the read mark
    /// again instead of skipping it as accepted and only asking for the dialog.
    func testARetryAfterTheServerFellBehindAPushSendsItAgain() {
        let peer = self.setUpChat(userId: 2305)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.behindAnswer(userId: 2305) })
        let ledger = PeerReadStatePushLedger()
        let payload = PeerReadStatePushLedger.Payload(maxIncomingReadId: 5, markedUnread: false)
        ledger.record(peerId: peer, payload: payload, generation: ledger.generation(peerId: peer))

        XCTAssertFalse(self.pushThenValidate(peer, ledger: ledger), "the server is behind: retry")
        XCTAssertEqual(self.count(self.readHistoryName), 0, "the first push is taken as accepted")
        XCTAssertNil(ledger.lastPush(peerId: peer), "the server is behind the recorded push")

        XCTAssertFalse(self.pushThenValidate(peer, ledger: ledger))
        XCTAssertEqual(self.count(self.readHistoryName), 1, "requests: \(self.server.requestNames)")
    }

    /// Runs one `Push(thenSync: true)`; true when it completed, false when it asked to retry.
    private func pushThenValidate(_ peer: PeerId, ledger: PeerReadStatePushLedger) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let completed = Atomic<Bool>(value: false)
        let disposable = synchronizePeerReadState(network: self.network, postbox: self.fixture.postbox, stateManager: self.stateManager, peerId: peer, push: true, validate: true, ledger: ledger).start(error: { _ in
            done.signal()
        }, completed: {
            let _ = completed.swap(true)
            done.signal()
        })
        if done.wait(timeout: .now() + 10.0) == .timedOut {
            XCTFail("push and validation did not finish")
        }
        disposable.dispose()
        self.drainOperationQueue()
        return completed.with { $0 }
    }
}
