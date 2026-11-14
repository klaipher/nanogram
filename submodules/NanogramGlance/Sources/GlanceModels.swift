public import Foundation

/// "<accountId>:<peerId>": the same form the SiriKit widget configuration stores for a chosen chat.
public enum GlanceIdentifier {
    public static func make(accountId: Int64, peerId: Int64) -> String {
        return "\(accountId):\(peerId)"
    }

    public static func parse(_ value: String) -> (accountId: Int64, peerId: Int64)? {
        guard let separator = value.firstIndex(of: ":") else {
            return nil
        }
        guard let accountId = Int64(value[value.startIndex ..< separator]), let peerId = Int64(value[value.index(after: separator)...]) else {
            return nil
        }
        return (accountId, peerId)
    }
}

public struct GlancePeerRef: Codable, Equatable, Hashable, Sendable {
    public var accountId: Int64
    public var peerId: Int64
    public var title: String
    public var isSavedMessages: Bool

    public init(accountId: Int64, peerId: Int64, title: String, isSavedMessages: Bool = false) {
        self.accountId = accountId
        self.peerId = peerId
        self.title = title
        self.isSavedMessages = isSavedMessages
    }

    public var identifier: String {
        return GlanceIdentifier.make(accountId: self.accountId, peerId: self.peerId)
    }
}

/// What the app shares with its widgets and intents through the app group. `enabled` is the Debug switch: while it is
/// off the app writes no peers and every surface shows its empty state or refuses. `peers` is empty while the app is
/// passcode-locked.
public struct GlanceSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion: Int = 1

    public var version: Int
    public var enabled: Bool
    public var displayNameOnLockscreen: Bool
    public var peers: [GlancePeerRef]
    public var savedMessages: GlancePeerRef?

    public init(enabled: Bool, displayNameOnLockscreen: Bool, peers: [GlancePeerRef], savedMessages: GlancePeerRef?) {
        self.version = GlanceSnapshot.currentVersion
        self.enabled = enabled
        self.displayNameOnLockscreen = displayNameOnLockscreen
        self.peers = peers
        self.savedMessages = savedMessages
    }

    public static let disabled = GlanceSnapshot(enabled: false, displayNameOnLockscreen: false, peers: [], savedMessages: nil)
}
