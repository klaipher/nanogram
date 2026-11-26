import Foundation
import UserNotifications

/// The one short-log line that ends every notification request: what was handed back, whether it was a call, how
/// long the request took and whether the system's time ran out. The short log (`critlog-*.txt`) is kept in every
/// build, the full log only when logging to file is on, so without this line the extension's short log never said
/// how a push ended. No content and no ids beyond the random episode.
enum NotificationServiceOutcome {
    enum Ending {
        case completed
        case timeExpired
    }

    enum Delivered: String {
        /// Nothing was handed back.
        case nothing
        /// The extension produced nothing; the server's own alert went out.
        case serverAlert = "server alert"
        /// A quiet copy of the server's alert, removed again (`ServicePushPresentation`).
        case quietPlaceholder = "quiet placeholder"
        /// Empty content: a service push the app may drop.
        case silent
        /// Content the extension made.
        case alert
    }

    static func delivered(generated: Bool, result: (content: UNNotificationContent, isQuietPlaceholder: Bool)?) -> Delivered {
        guard let result else {
            return .nothing
        }
        if !generated {
            return .serverAlert
        }
        if result.isQuietPlaceholder {
            return .quietPlaceholder
        }
        if ServicePushPresentation.isEmpty(result.content) {
            return .silent
        }
        return .alert
    }

    /// Whether the request was a call: the extension's own content or what was handed back carries the ring marker
    /// or the quiet-call marker. The handed-back content alone misses two calls: a quieted call's content has only the
    /// quiet marker, and for an empty call alert the server's own payload goes back, which has neither.
    static func isCall(generatedUserInfo: [AnyHashable: Any]?, deliveredUserInfo: [AnyHashable: Any]?) -> Bool {
        for userInfo in [generatedUserInfo, deliveredUserInfo] {
            guard let userInfo else {
                continue
            }
            if IncomingCallPushPresentation.isIncomingCall(userInfo: userInfo) || IncomingCallPushPresentation.isQuietCall(userInfo: userInfo) {
                return true
            }
        }
        return false
    }

    static func line(episode: String, ending: Ending, delivered: Delivered, isCall: Bool, duration: Double) -> String {
        var line = "NotificationService \(episode) outcome: \(delivered.rawValue)"
        if isCall {
            line += ", call"
        }
        line += " after " + String(format: "%.2f", duration) + " s"
        if case .timeExpired = ending {
            line += ", time expired"
        }
        return line
    }
}
