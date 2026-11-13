import Foundation

/// An answer or end action CallKit delivered for a call the app does not hold yet: a VoIP push or the
/// extension's hand-off lets CallKit ring a call before the app's own connection created it. The action
/// waits, for exactly that call's UUID, and is applied when the call is created, or dropped after `timeout`.
struct CallKitPendingActions {
    enum Action: Equatable {
        case answer
        case end
    }

    static let timeout: TimeInterval = 10.0

    private var entries: [UUID: (action: Action, date: Date)] = [:]

    var isEmpty: Bool {
        return self.entries.isEmpty
    }

    /// An end outlives an answer for the same call: a call declined after being answered is over.
    mutating func store(_ action: Action, uuid: UUID, now: Date) {
        self.removeExpired(now: now)
        if let existing = self.entries[uuid], existing.action == .end {
            return
        }
        self.entries[uuid] = (action, now)
    }

    /// The action waiting for exactly this UUID, if it is still fresh.
    mutating func take(uuid: UUID, now: Date) -> Action? {
        self.removeExpired(now: now)
        return self.entries.removeValue(forKey: uuid)?.action
    }

    private mutating func removeExpired(now: Date) {
        self.entries = self.entries.filter { now.timeIntervalSince($0.value.date) <= CallKitPendingActions.timeout }
    }
}
