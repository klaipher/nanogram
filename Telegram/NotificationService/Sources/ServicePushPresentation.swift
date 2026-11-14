import Foundation
import UserNotifications
import NotificationsPresentationData

/// Service pushes (a chat read on another device, deleted messages, read reactions, read
/// stories) carry no message: the extension answers them with empty content. Only an app with
/// the notification filtering entitlement can drop a push that way. Without it iOS shows the
/// server's placeholder alert ("You have a new message") instead, so a build without the
/// entitlement delivers that placeholder quietly (no sound, no screen wake) and removes it again.
/// Call pushes are left out (see `presentation`).
enum ServicePushPresentation {
    /// Marks a quiet placeholder this extension delivered, so later requests and the app can
    /// remove leftovers.
    static let userInfoKey = ServicePushNotifications.placeholderUserInfoKey
    static let threadIdentifier = "nanogram.servicePush"
    /// Removing a notification right after handing it back can race its posting, and the
    /// extension may be suspended before a late attempt runs: try early, then once more.
    static let removalDelays: [Double] = [0.3, 1.0]

    /// Telegram/BUILD sets this Info.plist flag from the same condition that grants
    /// `com.apple.developer.usernotifications.filtering`, so the two cannot drift apart.
    static let filteringInfoPlistKey = "NanogramNotificationFiltering"

    static func appCanFilterNotifications(infoDictionary: [String: Any]?) -> Bool {
        return (infoDictionary?[filteringInfoPlistKey] as? Bool) == true
    }

    static func isEmpty(_ content: UNNotificationContent) -> Bool {
        return content.title.isEmpty && content.subtitle.isEmpty && content.body.isEmpty
    }

    /// What to hand back for content the extension generated. Content with nothing to show is
    /// replaced by a quiet copy of the server's placeholder when the app cannot filter.
    /// Returns the content and whether it is such a placeholder.
    ///
    /// A call push is never quieted: when the extension produced no alert for it (it did not get
    /// as far as `IncomingCallPushPresentation`), the server's own alert goes out unchanged,
    /// sound included, and stays.
    static func presentation(generated: UNNotificationContent, initialContent: UNNotificationContent?, canFilter: Bool) -> (content: UNNotificationContent, isQuietPlaceholder: Bool) {
        if IncomingCallPushPresentation.isQuietCall(userInfo: generated.userInfo) {
            return (IncomingCallPushPresentation.quieted(generated), true)
        }
        guard !canFilter, isEmpty(generated), let initialContent, !isEmpty(initialContent) else {
            return (generated, false)
        }
        if IncomingCallPushPresentation.isIncomingCall(userInfo: generated.userInfo) {
            return (initialContent, false)
        }
        guard let content = initialContent.mutableCopy() as? UNMutableNotificationContent else {
            return (generated, false)
        }
        content.sound = nil
        content.badge = generated.badge
        content.threadIdentifier = threadIdentifier
        content.interruptionLevel = .passive
        content.relevanceScore = 0.0
        var userInfo = content.userInfo
        userInfo[userInfoKey] = true
        content.userInfo = userInfo
        return (content, true)
    }

    static func isQuietPlaceholder(userInfo: [AnyHashable: Any]) -> Bool {
        return ServicePushNotifications.isQuietPlaceholder(userInfo: userInfo)
    }

    /// Removes quiet placeholders still in Notification Center.
    static func removeDeliveredPlaceholders(center: UNUserNotificationCenter = .current()) {
        center.getDeliveredNotifications { notifications in
            let identifiers = notifications.compactMap { notification -> String? in
                return isQuietPlaceholder(userInfo: notification.request.content.userInfo) ? notification.request.identifier : nil
            }
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }
}
