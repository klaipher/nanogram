import Foundation
import Postbox

/// What the last successful read-state push of a peer told the server, so `ManagedSynchronizePeerReadStates` does not
/// repeat a `messages.readHistory` / `channels.readHistory` the server already answered. A push carries the maximum
/// incoming read id and the marked-unread flag; the rest of a `PeerReadState` (top known id, outgoing read id, unread
/// count) is local bookkeeping the server never sees.
///
/// One per `AccountStateManager`. The replay writes to it (`note(serverState:)`) from inside its Postbox
/// transaction, the synchronizer reads and writes it from its own queue, so it locks.
///
/// An entry is dropped whenever the server's own state may have moved away from it: a server read state or unread mark
/// that disagrees (another device marked the chat unread, a lower read id), and a push that was in flight while one was
/// noted is never recorded (`generation`).
final class PeerReadStatePushLedger {
    struct Payload: Equatable {
        let maxIncomingReadId: Int32
        let markedUnread: Bool
    }

    private let lock = NSLock()
    private var pushed: [PeerId: Payload] = [:]
    private var generations: [PeerId: Int] = [:]

    /// The payload the server last accepted for `peerId`, if it is still believed to hold.
    func lastPush(peerId: PeerId) -> Payload? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.pushed[peerId]
    }

    /// A token taken before a push goes out; `record` only stores the push if no server state was noted since.
    func generation(peerId: PeerId) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.generations[peerId] ?? 0
    }

    /// Records a push that succeeded entirely (every request of it answered).
    func record(peerId: PeerId, payload: Payload, generation: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if (self.generations[peerId] ?? 0) == generation {
            self.pushed[peerId] = payload
        }
    }

    func forget(peerId: PeerId) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pushed.removeValue(forKey: peerId)
        self.generations[peerId, default: 0] += 1
    }

    /// The server reported its read state for `peerId` (a read-state reset, validation) or its unread mark. Drops the
    /// entry when the server disagrees with it.
    func note(peerId: PeerId, serverMaxIncomingReadId: Int32?, serverMarkedUnread: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.generations[peerId, default: 0] += 1
        guard let entry = self.pushed[peerId] else {
            return
        }
        if entry.markedUnread != serverMarkedUnread || (serverMaxIncomingReadId.map({ $0 < entry.maxIncomingReadId }) ?? false) {
            self.pushed.removeValue(forKey: peerId)
        }
    }
}

extension PeerReadStateSynchronizationOperation {
    /// What this operation sends: two operations with equal payloads do the same work. The state a `Push` carries is
    /// a snapshot; the synchronizer re-reads the live one when it runs, so only the fields it sends count here.
    var syncPayload: PeerReadStateSyncPayload {
        switch self {
        case .Validate:
            return .validate
        case let .Push(state, thenSync):
            var key: PeerReadStatePushKey = .none
            if let state = state {
                for (namespace, readState) in state.states where namespace == Namespaces.Message.Cloud || namespace == Namespaces.Message.SecretIncoming {
                    switch readState {
                    case let .idBased(maxIncomingReadId, _, _, _, markedUnread):
                        key = .idBased(maxIncomingReadId: maxIncomingReadId, markedUnread: markedUnread)
                    case .indexBased:
                        // A secret chat's push is not deduplicated: keep the whole state.
                        key = .whole(state)
                    }
                    break
                }
            }
            return .push(key: key, thenSync: thenSync)
        }
    }
}

enum PeerReadStatePushKey: Equatable {
    case none
    case idBased(maxIncomingReadId: Int32, markedUnread: Bool)
    case whole(CombinedPeerReadState)
}

enum PeerReadStateSyncPayload: Equatable {
    case validate
    case push(key: PeerReadStatePushKey, thenSync: Bool)
}
