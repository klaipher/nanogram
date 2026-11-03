import Foundation
import UserNotifications

/// Telegram can deliver an incoming call as an encrypted regular push. The official app hands it to
/// CallKit from this extension (`CXProvider.reportNewIncomingVoIPPushPayload`), which iOS allows only
/// with the notification filtering entitlement. Without it iOS refuses the call, so the extension
/// shows the call as a ringing notification instead, as the official app does with CallKit off.
enum IncomingCallPushPresentation {
    /// Marks content generated for a call push, so an empty answer is never turned into a quiet
    /// placeholder (`ServicePushPresentation`).
    static let userInfoKey = "nanogram.incomingCall"

    static var markerUserInfo: [AnyHashable: Any] {
        return [userInfoKey: true]
    }

    static func isIncomingCall(userInfo: [AnyHashable: Any]) -> Bool {
        return (userInfo[userInfoKey] as? Bool) == true
    }

    static func reportsToCallKit(systemIntegrationEnabled: Bool, canFilterNotifications: Bool) -> Bool {
        return systemIntegrationEnabled && canFilterNotifications
    }

    struct Alert: Equatable {
        var title: String?
        var body: String
    }

    /// "<caller>" / "is calling you" (`NotificationsPresentationData.incomingCallString`), as the
    /// official app words it without CallKit.
    static func alert(callerName: String?, incomingCallMessage: String) -> Alert {
        if let callerName, !callerName.isEmpty {
            return Alert(title: callerName, body: incomingCallMessage)
        } else {
            return Alert(title: nil, body: "Incoming Call")
        }
    }

    /// What the app's notification tap handler reads: the account, then the caller's chat. Opening
    /// the app brings the call itself in through the account's updates while it still rings.
    static func userInfo(accountId: Int64, peerId: Int64, fromUserId: Int64) -> [AnyHashable: Any] {
        var userInfo = markerUserInfo
        userInfo["accountId"] = "\(accountId)"
        userInfo["peerId"] = "\(peerId)"
        userInfo["from_id"] = "\(fromUserId)"
        return userInfo
    }

    /// The device's ringtone, the sound of an incoming call.
    static var sound: UNNotificationSound {
        if #available(iOS 15.2, *) {
            return .defaultRingtone
        } else {
            return .default
        }
    }
}
