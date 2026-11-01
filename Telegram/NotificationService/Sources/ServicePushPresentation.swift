import Foundation
import UserNotifications

/// Service pushes (a chat read on another device, deleted messages, read reactions, read
/// stories) carry no message: the extension answers them with empty content. Only an app with
/// the notification filtering entitlement can drop a push that way. Without it iOS shows the
/// server's placeholder alert ("You have a new message") instead, so a build without the
/// entitlement delivers that placeholder quietly (no sound, no screen wake) and removes it again.
enum ServicePushPresentation {
    /// Marks a quiet placeholder this extension delivered, so later requests can remove leftovers.
    static let userInfoKey = "nanogram.servicePush"
    static let threadIdentifier = "nanogram.servicePush"
    /// Removing a notification right after handing it back can race its posting.
    static let removalDelay: Double = 1.0

    /// Telegram/BUILD grants `com.apple.developer.usernotifications.filtering` to this bundle only.
    static func appCanFilterNotifications(baseAppBundleId: String) -> Bool {
        return baseAppBundleId == "ph.telegra.Telegraph"
    }

    /// The app's bundle id from the extension's (`<app>.NotificationService`).
    static func baseAppBundleId(extensionBundleId: String) -> String? {
        guard let lastDot = extensionBundleId.range(of: ".", options: .backwards) else {
            return nil
        }
        return String(extensionBundleId[..<lastDot.lowerBound])
    }

    static func isEmpty(_ content: UNNotificationContent) -> Bool {
        return content.title.isEmpty && content.subtitle.isEmpty && content.body.isEmpty
    }

    /// What to hand back for content the extension generated. Content with nothing to show is
    /// replaced by a quiet copy of the server's placeholder when the app cannot filter.
    /// Returns the content and whether it is such a placeholder.
    static func presentation(generated: UNNotificationContent, initialContent: UNNotificationContent?, canFilter: Bool) -> (content: UNNotificationContent, isQuietPlaceholder: Bool) {
        guard !canFilter, isEmpty(generated), let initialContent, !isEmpty(initialContent) else {
            return (generated, false)
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
        return (userInfo[userInfoKey] as? Bool) == true
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
