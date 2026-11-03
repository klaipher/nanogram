import Foundation

/// The conversations Nanogram donates to the system (`INSendMessageIntent`), which become the
/// share sheet's and Siri's chat suggestions: one identity and one set of rules for every donor
/// (the app on each send, the notification service extension on each message) and every reader
/// (the Share extension and the app when a suggestion is tapped).
///
/// A conversation is `tg<peer id>` (`PeerId.toInt64()`), never account-qualified: Siri and its
/// learned ranking already know that form. Donors donate only from the suggestions account
/// (`IntentsSettings.account`), so a reader resolves the chat in that account.
public enum SendMessageSuggestions {
    /// Who a tapped suggestion addresses. `accountPeerId` is the account's own peer id when the
    /// identifier names one (`tg<account peer id>:<peer id>`, accepted but not written).
    public struct Target: Equatable, Sendable {
        public var accountPeerId: Int64?
        public var peerId: Int64

        public init(accountPeerId: Int64?, peerId: Int64) {
            self.accountPeerId = accountPeerId
            self.peerId = peerId
        }
    }

    /// `conversationIdentifier`, and the recipient's `customIdentifier`, of a donated chat.
    public static func conversationIdentifier(peerId: Int64) -> String {
        return "tg\(peerId)"
    }

    /// The `INInteraction.groupIdentifier` per-chat removal (`INInteraction.delete(with:)`) matches.
    public static func groupIdentifier(peerId: Int64) -> String {
        return "sendMessage_\(peerId)"
    }

    /// `tg<peer id>`, a bare `<peer id>` (what older notification donations and Siri replies
    /// carry) or `tg<account peer id>:<peer id>`; nil for anything else.
    public static func target(identifier: String) -> Target? {
        var body = Substring(identifier)
        if body.hasPrefix("tg") {
            body = body.dropFirst(2)
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let peerId = Int64(parts[0]) else {
                return nil
            }
            return Target(accountPeerId: nil, peerId: peerId)
        case 2:
            guard identifier.hasPrefix("tg"), let accountPeerId = Int64(parts[0]), let peerId = Int64(parts[1]) else {
                return nil
            }
            return Target(accountPeerId: accountPeerId, peerId: peerId)
        default:
            return nil
        }
    }

    /// The chat a tapped suggestion's `INSendMessageIntent` names: its conversation first (set by
    /// every donor), then each recipient's custom identifier in turn (an incoming donation's only
    /// recipient is the account itself, with none).
    public static func target(conversationIdentifier: String?, recipientCustomIdentifiers: [String?]) -> Target? {
        if let conversationIdentifier, let target = target(identifier: conversationIdentifier) {
            return target
        }
        for identifier in recipientCustomIdentifiers {
            if let identifier, let target = target(identifier: identifier) {
                return target
            }
        }
        return nil
    }

    /// The signed-in account (its own peer id) a suggestion opens in: the one it names, else the
    /// suggestions account, else nil (the caller's current account). An account no longer
    /// signed in is never chosen.
    public static func accountPeerId(for target: Target, suggestionsAccountPeerId: Int64?, signedInAccountPeerIds: [Int64]) -> Int64? {
        for candidate in [target.accountPeerId, suggestionsAccountPeerId] {
            if let candidate, signedInAccountPeerIds.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// What kind of chat a donation is for, as the Siri & Search settings group them.
    public enum Subject: Equatable, Sendable {
        case savedMessages
        case contact
        case privateChat
        case group
        /// Channels, bots, support and secret chats are never suggested.
        case never
    }

    /// The user's choices in Siri & Search (`IntentsSettings`), without the settings type.
    public struct Rules: Equatable, Sendable {
        public var accountPeerId: Int64?
        public var contacts: Bool
        public var privateChats: Bool
        public var groups: Bool
        public var savedMessages: Bool
        /// "Suggest only shared chats": only sends from the share sheet are donated.
        public var onlyShared: Bool

        public init(accountPeerId: Int64?, contacts: Bool, privateChats: Bool, groups: Bool, savedMessages: Bool, onlyShared: Bool) {
            self.accountPeerId = accountPeerId
            self.contacts = contacts
            self.privateChats = privateChats
            self.groups = groups
            self.savedMessages = savedMessages
            self.onlyShared = onlyShared
        }

        /// Whether a chat of `subject` in the account `donorAccountPeerId` may be donated;
        /// `isShare` for a send from the share sheet (not a chat, nor a received message).
        /// Nothing is donated while a passcode is set, or for an archived chat.
        public func allowsDonation(subject: Subject, donorAccountPeerId: Int64, isArchived: Bool, hasPasscode: Bool, isShare: Bool = false) -> Bool {
            if hasPasscode || isArchived {
                return false
            }
            if self.onlyShared && !isShare {
                return false
            }
            if let accountPeerId = self.accountPeerId, accountPeerId != donorAccountPeerId {
                return false
            }
            switch subject {
            case .savedMessages:
                return self.savedMessages
            case .contact:
                return self.contacts
            case .privateChat:
                return self.privateChats
            case .group:
                return self.groups
            case .never:
                return false
            }
        }
    }
}

/// A notification that arrives while the app is in the foreground (`willPresent`).
public enum ForegroundNotificationPresentation {
    /// Whether the system shows it as a banner: only for an account other than the one on
    /// screen, or for a link (`url` in its userInfo); the open account's own messages are shown
    /// in-app. Otherwise the system is told to show nothing, which it must always be told.
    public static func showsBanner(notificationAccountId: Int64?, currentAccountId: Int64?, hasUrl: Bool) -> Bool {
        guard let currentAccountId, let notificationAccountId else {
            return false
        }
        return notificationAccountId != currentAccountId || hasUrl
    }
}
