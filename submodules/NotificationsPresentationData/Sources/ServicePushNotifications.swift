import Foundation

/// Service-push leftovers in Notification Center: shared by the notification service extension
/// (which tags them) and the app (which sweeps them).
///
/// Without the notification filtering entitlement a service push (a chat read on another device,
/// deleted messages, read reactions or stories) cannot be dropped: the extension delivers a quiet
/// placeholder and removes it a moment later, and when the extension never ran or failed, iOS shows
/// the server's own alert. Neither carries a peer and message id, so the app's read-state clearing
/// never matches them.
public enum ServicePushNotifications {
    /// `true` in the userInfo of a quiet placeholder the extension delivered.
    public static let placeholderUserInfoKey = "nanogram.servicePush"

    public static func isQuietPlaceholder(userInfo: [AnyHashable: Any]) -> Bool {
        return (userInfo[placeholderUserInfoKey] as? Bool) == true
    }

    /// The server's alert as it arrived, untouched by the extension: only `aps` and the encrypted
    /// payload `p`. The extension adds a peer and message id to every message it shows.
    public static func isServerFallback(userInfo: [AnyHashable: Any]) -> Bool {
        return userInfo.count == 2 && userInfo["aps"] != nil && userInfo["p"] != nil
    }

    /// Delivered notifications to remove. Server fallbacks may stand for a message the extension
    /// could not decrypt, so they are included only once the app is active and shows its chats.
    public static func staleIdentifiers(delivered: [(identifier: String, userInfo: [AnyHashable: Any])], includeServerFallbacks: Bool) -> [String] {
        return delivered.compactMap { item -> String? in
            if isQuietPlaceholder(userInfo: item.userInfo) {
                return item.identifier
            }
            if includeServerFallbacks && isServerFallback(userInfo: item.userInfo) {
                return item.identifier
            }
            return nil
        }
    }
}
