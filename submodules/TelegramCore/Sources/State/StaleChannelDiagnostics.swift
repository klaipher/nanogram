import Foundation
import Postbox
import SwiftSignalKit

/// Log-only diagnostics for channels whose chat-list entry shows an old top message until the channel is opened.
/// Nothing here changes behaviour. Lines carry ids, dates and counts, never message text; with "Remove sensitive
/// data" on, peer ids are cut to their last four digits.
enum StaleChannelDiagnostics {
    private struct Counters {
        var openedPeers = Set<PeerId>()
        var tooLongReceived = 0
        var tooLongSkipped = 0
        var lastDifferenceTime: Double?
    }

    /// The counters behind a lock. A class of our own rather than `Atomic`: `Atomic` is `Sendable` in the iOS build
    /// and not in the Mac's package build, so neither a plain `let` nor `nonisolated(unsafe)` is clean on both.
    private final class CounterStore: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Counters()

        func modify(_ f: (Counters) -> Counters) -> Counters {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            self.value = f(self.value)
            return self.value
        }
    }

    private static let counters = CounterStore()

    struct PollSnapshot {
        let ptsBefore: Int32?
    }

    private static func label(_ peerId: PeerId) -> String {
        if Logger.shared.redactSensitiveData {
            return "#\(abs(peerId.id._internalGetInt64Value()) % 10000)"
        }
        return "\(peerId)"
    }

    /// Once per peer per launch, when the first poll of a channel starts (a chat history was opened): what the chat
    /// list, the history table and the channel state hold before the poll.
    static func beginPoll(transaction: Transaction, peerId: PeerId) -> PollSnapshot? {
        var isFirst = false
        let _ = counters.modify { current in
            var updated = current
            isFirst = updated.openedPeers.insert(peerId).inserted
            return updated
        }
        if !isFirst {
            return nil
        }
        let listTop = transaction.getPeerChatListIndex(peerId)?.1.messageIndex
        let tableTop = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud)
        let channelState = transaction.getPeerChatState(peerId) as? ChannelState
        Logger.shared.log("StaleChannel", "open \(label(peerId)) listTop id=\(listTop.map { String($0.id.id) } ?? "nil") date=\(listTop.map { String($0.timestamp) } ?? "nil") tableMaxCloud id=\(tableTop.map { String($0.id.id) } ?? "nil") date=\(tableTop.map { String($0.timestamp) } ?? "nil") pts=\(channelState.map { String($0.pts) } ?? "nil") invalidatedPts=\(channelState?.invalidatedPts.map { String($0) } ?? "nil")")
        return PollSnapshot(ptsBefore: channelState?.pts)
    }

    static func endPoll(_ snapshot: PollSnapshot?, peerId: PeerId, state: AccountMutableState) {
        guard let snapshot else {
            return
        }
        var added = 0
        for operation in state.operations {
            if case let .AddMessages(messages, _) = operation {
                for message in messages where message.id.peerId == peerId && message.id.namespace == Namespaces.Message.Cloud {
                    added += 1
                }
            }
        }
        Logger.shared.log("StaleChannel", "polled \(label(peerId)) pts \(snapshot.ptsBefore.map { String($0) } ?? "nil") -> \(state.channelStates[peerId].map { String($0.pts) } ?? "nil") addedMessages=\(added)")
    }

    static func noteTooLong(peerId: PeerId, skipped: Bool) {
        let updated = counters.modify { current in
            var updated = current
            updated.tooLongReceived += 1
            if skipped {
                updated.tooLongSkipped += 1
            }
            return updated
        }
        Logger.shared.log("StaleChannel", "updateChannelTooLong \(label(peerId)) \(skipped ? "skipped by pts" : "polled") received=\(updated.tooLongReceived) skipped=\(updated.tooLongSkipped)")
    }

    static func noteDifference(kind: String) {
        let now = CFAbsoluteTimeGetCurrent()
        var previous: Double?
        let _ = counters.modify { current in
            var updated = current
            previous = updated.lastDifferenceTime
            updated.lastDifferenceTime = now
            return updated
        }
        Logger.shared.log("StaleChannel", "difference \(kind) sinceLast=\(previous.map { String(Int(now - $0)) + "s" } ?? "first")")
    }
}
