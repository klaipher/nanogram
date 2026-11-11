import Foundation
import XCTest
import SwiftSignalKit
import Postbox
import TelegramApi
@testable import TelegramCore

/// Validating a peer's read state asks `messages.getHistory(limit: 1)` only when no cloud message of the peer is stored
/// here; with one stored it goes straight to `messages.getPeerDialogs`. A dialog the server does not know falls back to
/// the probe once.
final class ReadStateValidationProbeTests: StateSyncTestCase {
    private let getHistoryName = "messages.getHistory"

    private enum Outcome {
        case completed
        case failed
    }

    private func count(_ name: String) -> Int {
        return self.server.requests.filter({ $0.name == name }).count
    }

    private func peerDialogsAnswer(userId: Int64) -> ScriptedAnswer {
        return .result(StateSyncApi.peerDialogs(dialogs: [StateSyncApi.dialog(peer: StateSyncApi.peerUser(userId), topMessage: 5, readInboxMaxId: 5, unreadCount: 0)], state: StateSyncApi.state(pts: 100, qts: 5, date: self.baseDate, seq: 10)))
    }

    private func noDialogAnswer() -> ScriptedAnswer {
        return .result(StateSyncApi.peerDialogs(state: StateSyncApi.state(pts: 100, qts: 5, date: self.baseDate, seq: 10)))
    }

    private func historyAnswer(userId: Int64, empty: Bool) -> ScriptedAnswer {
        if empty {
            return .result(StateSyncApi.messages([]))
        }
        return .result(StateSyncApi.messages([StateSyncApi.privateMessage(id: 5, peerUserId: userId, fromUserId: userId, date: Int32(clamping: Int64(self.baseDate) + 5))]))
    }

    private func setUpChat(userId: Int64, storedMessages: Bool) -> PeerId {
        let peer = self.seedUserChat(userId)
        if storedMessages {
            for id in 1 ... 5 as ClosedRange<Int32> {
                self.fixture.storeMessage(peerId: peer, id: id, timestamp: self.baseDate + id, authorId: peer, text: "m\(id)")
            }
        }
        self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 5, maxOutgoingReadId: 0, maxKnownId: 5, count: 0)
        self.launchIdle()
        self.fixture.transaction { transaction -> Void in
            transaction.setNeedsIncomingReadStateSynchronization(peer)
        }
        return peer
    }

    private func pendingOperation(_ peer: PeerId) -> PeerReadStateSynchronizationOperation? {
        return self.fixture.wait(self.fixture.postbox.synchronizePeerReadStatesView() |> map { $0.operations[peer] }) ?? nil
    }

    private func validate(_ peer: PeerId) -> Outcome {
        let done = DispatchSemaphore(value: 0)
        let result = Atomic<Outcome?>(value: nil)
        let disposable = synchronizePeerReadState(network: self.network, postbox: self.fixture.postbox, stateManager: self.stateManager, peerId: peer, push: false, validate: true).start(error: { _ in
            let _ = result.swap(.failed)
            done.signal()
        }, completed: {
            let _ = result.swap(.completed)
            done.signal()
        })
        if done.wait(timeout: .now() + 10.0) == .timedOut {
            XCTFail("validation did not finish")
        }
        disposable.dispose()
        self.drainOperationQueue()
        return result.with { $0 } ?? .failed
    }

    func testAChatWithAStoredMessageIsValidatedWithOneRequest() {
        let peer = self.setUpChat(userId: 2201, storedMessages: true)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.peerDialogsAnswer(userId: 2201) })
        self.server.always(self.getHistoryName, { _ in self.historyAnswer(userId: 2201, empty: false) })

        XCTAssertEqual(self.validate(peer), .completed)

        XCTAssertEqual(self.count(StateSyncRequestName.getPeerDialogs), 1)
        XCTAssertEqual(self.count(self.getHistoryName), 0)
        XCTAssertNil(self.pendingOperation(peer))
    }

    func testAChatWithNoStoredMessageIsStillProbed() {
        let peer = self.setUpChat(userId: 2202, storedMessages: false)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.peerDialogsAnswer(userId: 2202) })
        self.server.always(self.getHistoryName, { _ in self.historyAnswer(userId: 2202, empty: false) })

        XCTAssertEqual(self.validate(peer), .completed)

        XCTAssertEqual(self.count(self.getHistoryName), 1)
        XCTAssertEqual(self.count(StateSyncRequestName.getPeerDialogs), 1)
    }

    func testAnEmptyChatConfirmsWithoutAskingForTheDialog() {
        let peer = self.setUpChat(userId: 2203, storedMessages: false)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.peerDialogsAnswer(userId: 2203) })
        self.server.always(self.getHistoryName, { _ in self.historyAnswer(userId: 2203, empty: true) })

        XCTAssertEqual(self.validate(peer), .completed)

        XCTAssertEqual(self.count(self.getHistoryName), 1)
        XCTAssertEqual(self.count(StateSyncRequestName.getPeerDialogs), 0)
        XCTAssertNil(self.pendingOperation(peer))
    }

    /// A chat deleted on the server while a message is still stored here: no dialog, then the probe finds it empty. It
    /// confirms, once, and does not loop.
    func testADeletedChatWithAStoredMessageConfirmsAfterOneProbe() {
        let peer = self.setUpChat(userId: 2204, storedMessages: true)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.noDialogAnswer() })
        self.server.always(self.getHistoryName, { _ in self.historyAnswer(userId: 2204, empty: true) })

        XCTAssertEqual(self.validate(peer), .completed)

        XCTAssertEqual(self.count(StateSyncRequestName.getPeerDialogs), 1)
        XCTAssertEqual(self.count(self.getHistoryName), 1)
        XCTAssertNil(self.pendingOperation(peer))
    }

    /// No dialog but a non-empty chat is what asked to retry before: it still does.
    func testNoDialogForANonEmptyChatStillRetries() {
        let peer = self.setUpChat(userId: 2205, storedMessages: true)
        self.server.always(StateSyncRequestName.getPeerDialogs, { _ in self.noDialogAnswer() })
        self.server.always(self.getHistoryName, { _ in self.historyAnswer(userId: 2205, empty: false) })

        XCTAssertEqual(self.validate(peer), .failed)

        XCTAssertEqual(self.count(StateSyncRequestName.getPeerDialogs), 1)
        XCTAssertEqual(self.count(self.getHistoryName), 1)
        XCTAssertNotNil(self.pendingOperation(peer))
    }
}
