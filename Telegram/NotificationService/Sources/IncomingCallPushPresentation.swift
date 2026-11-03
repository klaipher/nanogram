import Foundation
import UserNotifications
import CallKit
import NotificationsPresentationData

/// Telegram can deliver an incoming call as an encrypted regular push. The official app hands it to
/// CallKit from this extension (`CXProvider.reportNewIncomingVoIPPushPayload`), which iOS allows only
/// with the notification filtering entitlement. Without it iOS refuses the call, so the extension
/// shows the call as a ringing notification instead, as the official app does with CallKit off.
enum IncomingCallPushPresentation {
    /// Marks content generated for a call push, so an empty answer is never turned into a quiet
    /// placeholder (`ServicePushPresentation`), and so the app can take the ringing notification
    /// down (`IncomingCallNotifications`).
    static let userInfoKey = IncomingCallNotifications.userInfoKey

    static var markerUserInfo: [AnyHashable: Any] {
        return [userInfoKey: true]
    }

    static func isIncomingCall(userInfo: [AnyHashable: Any]) -> Bool {
        return IncomingCallNotifications.isIncomingCall(userInfo: userInfo)
    }

    static func reportsToCallKit(systemIntegrationEnabled: Bool, canFilterNotifications: Bool) -> Bool {
        return systemIntegrationEnabled && canFilterNotifications
    }

    /// Whether a call CallKit refused from the extension still rings as a notification. Only when
    /// CallKit could not take it at all (no entitlement, unknown failure): a caller the user blocked,
    /// Do Not Disturb, the restricted and protected modes, or a call CallKit already shows (the app's
    /// VoIP push came first) are CallKit's answer, and ringing anyway would override it or ring twice.
    static func ringsAfterCallKitError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == CXErrorDomainIncomingCall else {
            return true
        }
        switch error.code {
        case CXErrorCodeIncomingCallError.Code.unknown.rawValue, CXErrorCodeIncomingCallError.Code.unentitled.rawValue:
            return true
        default:
            return false
        }
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
