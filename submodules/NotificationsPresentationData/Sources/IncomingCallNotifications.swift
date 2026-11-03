import Foundation

/// The ringing "<caller> is calling you" notification the notification service extension shows
/// when it cannot hand a call push to CallKit: shared by the extension (which marks it) and the
/// app (which takes it down).
///
/// It plays the ringtone, and nothing in iOS removes it when the call is answered, declined or
/// missed. The app removes it once it rings the call itself through CallKit (a VoIP push, or its own
/// connection while alive) or the call stops ringing, and sweeps any left past the ring timeout.
public enum IncomingCallNotifications {
    /// `true` in the userInfo of the extension's call notification, which also carries the
    /// caller's `peerId` (`PeerId.toInt64()`, as a string).
    public static let userInfoKey = "nanogram.incomingCall"

    /// The server's default `call_ring_timeout_ms`: no call rings longer.
    public static let ringTimeout: TimeInterval = 90.0

    public static func isIncomingCall(userInfo: [AnyHashable: Any]) -> Bool {
        return (userInfo[userInfoKey] as? Bool) == true
    }

    /// Delivered call notifications for the caller `peerId` (`PeerId.toInt64()`).
    public static func identifiers(delivered: [(identifier: String, userInfo: [AnyHashable: Any])], peerId: Int64) -> [String] {
        let peerIdString = "\(peerId)"
        return delivered.compactMap { item -> String? in
            guard isIncomingCall(userInfo: item.userInfo), (item.userInfo["peerId"] as? String) == peerIdString else {
                return nil
            }
            return item.identifier
        }
    }

    /// Delivered call notifications older than any call rings.
    public static func staleIdentifiers(delivered: [(identifier: String, userInfo: [AnyHashable: Any], date: Date)], now: Date) -> [String] {
        return delivered.compactMap { item -> String? in
            guard isIncomingCall(userInfo: item.userInfo), now.timeIntervalSince(item.date) > ringTimeout else {
                return nil
            }
            return item.identifier
        }
    }

    /// Whether the extension's notification for an incoming call the app knows about must go: CallKit
    /// rings that call itself, or the call no longer rings. Without CallKit the notification is the
    /// only ring a backgrounded app has, so it stays while the call rings.
    public static func appRingsOrCallEnded(isIntegratedWithCallKit: Bool, isRinging: Bool) -> Bool {
        return isIntegratedWithCallKit || !isRinging
    }
}
