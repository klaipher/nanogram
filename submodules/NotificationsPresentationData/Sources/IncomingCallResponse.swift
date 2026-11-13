import Foundation
import UserNotifications

/// What the app does with the user's response to a ringing call notification, and how it takes the
/// notifications down. The notification is the extension's ring (carrying the call,
/// `IncomingCallNotificationRouting`) or the app's own ring while it runs in the background (carrying
/// only the caller and `localRingKey`).
public enum IncomingCallResponse {
    /// `true` in the userInfo of the ring the app posts itself for a call it rings without CallKit.
    public static let localRingKey = "nanogram.incomingCall.local"

    public enum Kind: Equatable, Sendable {
        /// A tap on the notification: show the call, ringing.
        case open
        /// The Answer action (the device is unlocked, the app is in the foreground).
        case answer
        /// The Decline action, taken without opening the app.
        case decline
    }

    public struct Plan: Equatable, Sendable {
        public var kind: Kind
        /// The call the extension's ring carries; nil for the app's own ring, whose call is the
        /// app's current call.
        public var call: IncomingCallNotificationRouting.Call?

        public init(kind: Kind, call: IncomingCallNotificationRouting.Call?) {
            self.kind = kind
            self.call = call
        }
    }

    /// Nil for a notification that is not an incoming call ring, or for an action that is none of
    /// the ring's (a dismissal).
    public static func plan(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Plan? {
        guard IncomingCallNotifications.isIncomingCall(userInfo: userInfo) else {
            return nil
        }
        let kind: Kind
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            kind = .open
        case IncomingCallNotificationRouting.answerActionIdentifier:
            kind = .answer
        case IncomingCallNotificationRouting.declineActionIdentifier:
            kind = .decline
        default:
            return nil
        }
        return Plan(kind: kind, call: IncomingCallNotificationRouting.call(userInfo: userInfo))
    }

    /// The account and the caller's chat a ring names, for the fallback that only opens the app.
    public static func caller(userInfo: [AnyHashable: Any]) -> (accountId: Int64?, peerId: Int64)? {
        guard IncomingCallNotifications.isIncomingCall(userInfo: userInfo), let peerId = (userInfo[IncomingCallNotificationRouting.Key.peerId] as? String).flatMap({ Int64($0) }) else {
            return nil
        }
        let accountId = (userInfo[IncomingCallNotificationRouting.Key.accountId] as? String).flatMap({ Int64($0) })
        return (accountId, peerId)
    }

    /// The push's base64url `updates`, decoded.
    public static func updatesData(_ updates: String) -> Data? {
        var string = updates.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while string.count % 4 != 0 {
            string.append("=")
        }
        return Data(base64Encoded: string)
    }

    public static func isLocalRing(userInfo: [AnyHashable: Any]) -> Bool {
        return (userInfo[localRingKey] as? Bool) == true
    }

    /// The userInfo of the ring the app posts itself for a call from `peerId` (`PeerId.toInt64()`).
    public static func localRingUserInfo(peerId: Int64) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [IncomingCallNotifications.userInfoKey: true]
        userInfo[IncomingCallNotificationRouting.Key.peerId] = "\(peerId)"
        userInfo[localRingKey] = true
        return userInfo
    }

    /// How a ring shows while the app is in the foreground. The app's own ring is the only audible
    /// one of a call without CallKit (the app shows the call itself, so no banner); the extension's
    /// shows only for another account than the one on screen, as every notification does.
    public static func foregroundOptions(userInfo: [AnyHashable: Any], showsBanner: Bool) -> UNNotificationPresentationOptions {
        if isLocalRing(userInfo: userInfo) {
            return [.sound, .list]
        }
        return showsBanner ? [.banner, .list] : []
    }

    /// Takes down the delivered rings of a call from `peerId` (`PeerId.toInt64()`), the extension's and
    /// the app's own alike.
    public static func removeDeliveredRings(peerId: Int64, center: UNUserNotificationCenter = .current(), completion: @escaping @Sendable (Int) -> Void = { _ in }) {
        nonisolated(unsafe) let center = center
        center.getDeliveredNotifications(completionHandler: { notifications in
            let delivered = notifications.map { notification -> (identifier: String, userInfo: [AnyHashable: Any]) in
                return (notification.request.identifier, notification.request.content.userInfo)
            }
            let identifiers = IncomingCallNotifications.identifiers(delivered: delivered, peerId: peerId)
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
            completion(identifiers.count)
        })
    }
}
