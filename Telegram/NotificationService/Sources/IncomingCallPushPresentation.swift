import Foundation
import UserNotifications
import CallKit
import TelegramCore
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

    /// How long the extension waits for the server to take the call's acknowledgement before it
    /// hands the ring back: a ring is held back by at most this long, as the caller's window is short.
    static let acknowledgementTimeout: Double = 0.8

    /// Runs `action` once `count` completions arrived, from any thread; further ones do nothing.
    final class CompletionJoin: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var action: (() -> Void)?

        init(count: Int, action: @escaping () -> Void) {
            self.remaining = count
            self.action = action
        }

        func complete() {
            self.lock.lock()
            self.remaining -= 1
            let action: (() -> Void)?
            if self.remaining <= 0 {
                action = self.action
                self.action = nil
            } else {
                action = nil
            }
            self.lock.unlock()
            action?()
        }
    }

    /// Hands the call to CallKit, or rings it as a notification. The ringing content is made only
    /// to be shown (without CallKit, or after `ringsAfterCallKitError`): what it looks up and draws
    /// for the caller never delays handing the call to CallKit. A call that rings as a notification
    /// is also acknowledged to the server (`acknowledgeRing`, started with the ring, so the caller
    /// sees "Ringing"); a call CallKit takes is acknowledged by the app CallKit starts.
    static func present<Content>(
        reportsToCallKit: Bool,
        reportToCallKit: (@escaping (Error?) -> Void) -> Void,
        makeRingingContent: @escaping (@escaping (Content) -> Void) -> Void,
        showRingingContent: @escaping (Content) -> Void,
        acknowledgeRing: @escaping (@escaping () -> Void) -> Void = { done in done() },
        completed: @escaping () -> Void
    ) {
        let ring: () -> Void = {
            let join = CompletionJoin(count: 2, action: completed)
            acknowledgeRing {
                join.complete()
            }
            makeRingingContent { content in
                showRingingContent(content)
                join.complete()
            }
        }
        if reportsToCallKit {
            reportToCallKit { error in
                if let error, ringsAfterCallKitError(error) {
                    ring()
                } else {
                    completed()
                }
            }
        } else {
            ring()
        }
    }

    /// The interruption level as the notification log names it.
    static func interruptionLevelName(_ level: UNNotificationInterruptionLevel) -> String {
        switch level {
        case .passive:
            return "passive"
        case .active:
            return "active"
        case .timeSensitive:
            return "timeSensitive"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown(\(level.rawValue))"
        }
    }

    /// What the notification log says about CallKit's answer: its domain and code, never more.
    static func callKitResultDescription(_ error: Error?) -> String {
        guard let error else {
            return "none"
        }
        let nsError = error as NSError
        return "domain: \(nsError.domain), code: \(nsError.code), rings: \(ringsAfterCallKitError(nsError))"
    }

    /// Whether a fetched message is the service message of a finished call (answered, missed or
    /// declined): the moment a ring for that caller is over.
    static func isPhoneCallServiceMessage(media: [Any]) -> Bool {
        for item in media {
            if let action = item as? TelegramMediaAction, case .phoneCall = action.action {
                return true
            }
        }
        return false
    }

    struct Alert: Equatable {
        var title: String?
        var body: String
    }

    /// "<caller>" / "is calling you" (`NotificationsPresentationData.incomingCallString`), as the
    /// official app words it without CallKit.
    static func alert(callerName: String?, incomingCallMessage: String, anonymousBody: String = "Incoming Call") -> Alert {
        if let callerName, !callerName.isEmpty {
            return Alert(title: callerName, body: incomingCallMessage)
        } else {
            return Alert(title: nil, body: anonymousBody)
        }
    }

    /// What the app's notification handler reads: the account, the caller's chat and, for a 1:1
    /// call, the call itself (`IncomingCallNotificationRouting`), so a tap or Answer can bring the
    /// call in without waiting for the account's updates, and Decline can end it.
    static func userInfo(accountId: Int64, peerId: Int64, fromUserId: Int64, call: IncomingCallNotificationRouting.Call? = nil) -> [AnyHashable: Any] {
        var userInfo = markerUserInfo
        userInfo[IncomingCallNotificationRouting.Key.accountId] = "\(accountId)"
        userInfo[IncomingCallNotificationRouting.Key.peerId] = "\(peerId)"
        userInfo[IncomingCallNotificationRouting.Key.fromId] = "\(fromUserId)"
        if let call {
            for (key, value) in IncomingCallNotificationRouting.userInfo(call: call) {
                userInfo[key] = value
            }
        }
        return userInfo
    }

    /// Answer and Decline only on a 1:1 call: a group call invite has nothing to answer or decline
    /// from a notification.
    static func categoryIdentifier(isGroupCall: Bool) -> String? {
        return isGroupCall ? nil : IncomingCallNotificationRouting.categoryIdentifier
    }

    static func threadIdentifier(accountId: Int64, peerId: Int64) -> String {
        return IncomingCallNotificationRouting.threadIdentifier(accountId: accountId, peerId: peerId)
    }

    /// The caller's name for the banner: none while the passcode lock is on or names are hidden on
    /// the lock screen, where a message names no sender either.
    static func shownCallerName(_ callerName: String?, isAppLocked: Bool, displayNameOnLockscreen: Bool) -> String? {
        return (isAppLocked || !displayNameOnLockscreen) ? nil : callerName
    }

    /// Time Sensitive, so a Focus or the scheduled summary does not hold the ring back. Without the
    /// entitlement iOS treats it as an ordinary (active) notification, so it is always set.
    static func applyDelivery(to content: UNMutableNotificationContent) {
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0
    }

    /// A bundled sound of at most 30 s (`Telegram-iOS/Resources/notifications`), for a ring the system
    /// refused to update from the call intent: the ringtone constant plays only for intent-updated
    /// content.
    static let fallbackSoundName = "0.m4a"

    static var fallbackSound: UNNotificationSound {
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: fallbackSoundName))
    }

    /// Delivered call rings older than any call rings (`IncomingCallNotifications.ringTimeout`).
    static func staleRingIdentifiers(_ delivered: [UNNotification], now: Date = Date()) -> [String] {
        return IncomingCallNotifications.staleIdentifiers(
            delivered: delivered.map { ($0.request.identifier, $0.request.content.userInfo, $0.date) },
            now: now
        )
    }

    /// The identifiers of delivered call rings from `peerId` to `accountId`.
    static func ringIdentifiers(_ delivered: [UNNotification], accountId: Int64, peerId: Int64) -> [String] {
        return IncomingCallNotificationRouting.identifiers(
            delivered: delivered.map { ($0.request.identifier, $0.request.content.userInfo) },
            accountId: accountId,
            peerId: peerId
        )
    }

    /// Takes down rings past the ring timeout, whichever call they were for.
    static func removeStaleRings(center: UNUserNotificationCenter = .current(), now: @escaping () -> Date = { Date() }) {
        center.getDeliveredNotifications { notifications in
            let identifiers = staleRingIdentifiers(notifications, now: now())
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
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
