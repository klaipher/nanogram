import Foundation

/// What the extension's ringing call notification carries so the app can take its action:
/// shared by the extension (which writes it) and the app (which registers the category and reads
/// the response). The call keys are the ones of the VoIP push payload the app already parses.
public enum IncomingCallNotificationRouting {
    /// The notification category of a 1:1 incoming call. A group call invite has none.
    public static let categoryIdentifier = "incomingCall"
    /// Opens the app and answers the call (needs the device unlocked).
    public static let answerActionIdentifier = "incomingCall.answer"
    /// Declines the call without opening the app.
    public static let declineActionIdentifier = "incomingCall.decline"

    /// The userInfo keys, all values strings (`isVideo`: a Bool).
    public enum Key {
        /// `AccountRecordId` the call came to.
        public static let accountId = "accountId"
        /// The caller's `PeerId.toInt64()`.
        public static let peerId = "peerId"
        /// The caller's user id (`PeerId.Id` value).
        public static let fromId = "from_id"
        public static let callId = "call_id"
        public static let callAccessHash = "call_ah"
        /// The base64url `updates` of the push: the `updatePhoneCall` the app feeds to the
        /// account's state manager to ring the call without waiting for a difference.
        public static let updates = "updates"
        public static let isVideo = "isVideo"
    }

    /// The call a ringing notification stands for.
    public struct Call: Equatable, Sendable {
        public var accountId: Int64
        public var peerId: Int64
        public var fromId: Int64
        public var callId: Int64
        public var accessHash: Int64
        public var updates: String
        public var isVideo: Bool

        public init(accountId: Int64, peerId: Int64, fromId: Int64, callId: Int64, accessHash: Int64, updates: String, isVideo: Bool) {
            self.accountId = accountId
            self.peerId = peerId
            self.fromId = fromId
            self.callId = callId
            self.accessHash = accessHash
            self.updates = updates
            self.isVideo = isVideo
        }
    }

    /// One thread per caller and account, so a repeated ring replaces nothing but stacks with its own.
    public static func threadIdentifier(accountId: Int64, peerId: Int64) -> String {
        return "nanogram.call.\(accountId).\(peerId)"
    }

    /// The call keys of `call`, to add to the notification's userInfo.
    public static func userInfo(call: Call) -> [AnyHashable: Any] {
        return [
            Key.callId: "\(call.callId)",
            Key.callAccessHash: "\(call.accessHash)",
            Key.updates: call.updates,
            Key.isVideo: call.isVideo
        ]
    }

    /// Nil unless the userInfo is an incoming call notification with every key the app needs.
    public static func call(userInfo: [AnyHashable: Any]) -> Call? {
        guard IncomingCallNotifications.isIncomingCall(userInfo: userInfo),
              let accountId = (userInfo[Key.accountId] as? String).flatMap({ Int64($0) }),
              let peerId = (userInfo[Key.peerId] as? String).flatMap({ Int64($0) }),
              let fromId = (userInfo[Key.fromId] as? String).flatMap({ Int64($0) }),
              let callId = (userInfo[Key.callId] as? String).flatMap({ Int64($0) }),
              let accessHash = (userInfo[Key.callAccessHash] as? String).flatMap({ Int64($0) }),
              let updates = userInfo[Key.updates] as? String
        else {
            return nil
        }
        return Call(accountId: accountId, peerId: peerId, fromId: fromId, callId: callId, accessHash: accessHash, updates: updates, isVideo: (userInfo[Key.isVideo] as? Bool) ?? false)
    }

    /// Delivered call notifications for the caller `peerId` of `accountId`.
    public static func identifiers(delivered: [(identifier: String, userInfo: [AnyHashable: Any])], accountId: Int64, peerId: Int64) -> [String] {
        let accountIdString = "\(accountId)"
        return delivered.compactMap { item -> String? in
            guard (item.userInfo[Key.accountId] as? String) == accountIdString else {
                return nil
            }
            return IncomingCallNotifications.identifiers(delivered: [item], peerId: peerId).first
        }
    }
}
