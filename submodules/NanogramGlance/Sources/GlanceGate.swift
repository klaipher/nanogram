public import Foundation

/// What the coordinator derives every surface from. `locked` is the app passcode lock only: an app that is merely in
/// the background, with no passcode set, is not locked.
public struct GlanceGate: Equatable, Sendable {
    public var enabled: Bool
    public var displayNames: Bool
    public var locked: Bool

    public init(enabled: Bool, displayNames: Bool, locked: Bool) {
        self.enabled = enabled
        self.displayNames = displayNames
        self.locked = locked
    }

    public var lockPhase: GlanceLockPhase {
        return self.locked ? .locked : .unlocked
    }

    /// Chats are listed (widget picker, Shortcuts suggestions) only while the feature is on and the app is unlocked.
    public var listsChats: Bool {
        return self.enabled && !self.locked
    }

    public var allowsSending: Bool {
        return self.enabled && !self.locked
    }
}

public enum GlanceSnapshotBuilder {
    public static func make(gate: GlanceGate, peers: [GlancePeerRef], savedMessages: GlancePeerRef?) -> GlanceSnapshot {
        guard gate.enabled else {
            return GlanceSnapshot.disabled
        }
        return GlanceSnapshot(enabled: true, displayNameOnLockscreen: gate.displayNames, peers: gate.listsChats ? peers : [], savedMessages: savedMessages)
    }
}

public extension GlanceSnapshot {
    /// Equal apart from the order of the chats, so a busy account that only reorders its top chats does not rewrite the file.
    func hasSameContent(as other: GlanceSnapshot) -> Bool {
        var lhs = self
        var rhs = other
        lhs.peers.sort(by: { $0.identifier < $1.identifier })
        rhs.peers.sort(by: { $0.identifier < $1.identifier })
        return lhs == rhs
    }
}

/// Resolves the identifiers an intent or widget configuration stored back to chats. Well-formed identifiers always
/// resolve: the snapshot's title when it is listed, otherwise the generic one, so a configured chat survives leaving
/// the top chats, the passcode lock and the feature switch.
public enum GlanceEntityResolver {
    public static func resolve(identifiers: [String], snapshot: GlanceSnapshot?, genericTitle: String) -> [GlancePeerRef] {
        var result: [GlancePeerRef] = []
        for identifier in identifiers {
            guard let parsed = GlanceIdentifier.parse(identifier) else {
                continue
            }
            let listed = snapshot?.peers.first(where: { $0.accountId == parsed.accountId && $0.peerId == parsed.peerId })
            result.append(listed ?? GlancePeerRef(accountId: parsed.accountId, peerId: parsed.peerId, title: genericTitle))
        }
        return result
    }

    /// Candidates for pickers and suggestions: only while the snapshot lists chats.
    public static func candidates(snapshot: GlanceSnapshot?) -> [GlancePeerRef] {
        guard let snapshot, snapshot.enabled else {
            return []
        }
        return snapshot.peers
    }
}
