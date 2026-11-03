import Foundation
import TelegramCore
import NotificationsPresentationData

/// The handle a call is known by outside the app: the CallKit handle of every call (Phone ▸ Recents) and the person of
/// the donated `INStartCallIntent` (Siri suggestions). Tapping either hands it back to the app, which calls that peer.
///
/// It names the account and the packed peer id (`IncomingCallNotifications.callBackIdentifier`, the form the
/// notification service extension already donates). Older builds wrote the raw user id, bare or as "tg<id>", and the
/// Siri extension "tg<packed id>"; those entries stay in Recents, so `parse` still reads them.
public enum CallKitHandle {
    public struct Parsed: Equatable {
        /// Nil for the older forms: they call from the current account.
        public var accountId: AccountRecordId?
        public var peerId: EnginePeer.Id

        public init(accountId: AccountRecordId?, peerId: EnginePeer.Id) {
            self.accountId = accountId
            self.peerId = peerId
        }
    }

    public static func value(accountId: AccountRecordId, peerId: EnginePeer.Id) -> String {
        return IncomingCallNotifications.callBackIdentifier(accountId: accountId.int64, peerId: peerId.toInt64())
    }

    /// Only users are called, so a number is a packed user id when its namespace bits say so, and a raw user id
    /// otherwise: a raw id of 2^32 or more decoded as packed would name a group with a truncated id. Raw ids below
    /// 2^35 (all user ids so far) are told apart this way.
    public static func parse(_ value: String) -> Parsed? {
        if let callBack = IncomingCallNotifications.callBack(identifier: value) {
            let peerId = EnginePeer.Id(callBack.peerId)
            guard peerId.namespace == Namespaces.Peer.CloudUser else {
                return nil
            }
            return Parsed(accountId: AccountRecordId(rawValue: callBack.accountId), peerId: peerId)
        }
        var digits = Substring(value)
        if digits.hasPrefix("tg") {
            digits = digits.dropFirst(2)
        }
        guard !digits.isEmpty, digits.allSatisfy({ ("0" ... "9").contains($0) }), let number = Int64(digits), number > 0 else {
            return nil
        }
        let namespaceBits = (UInt64(bitPattern: number) >> 32) & 0x7
        if namespaceBits == UInt64(Namespaces.Peer.CloudUser._internalGetInt32Value()) {
            let peerId = EnginePeer.Id(number)
            if peerId.namespace == Namespaces.Peer.CloudUser {
                return Parsed(accountId: nil, peerId: peerId)
            }
        }
        return Parsed(accountId: nil, peerId: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(number)))
    }
}
