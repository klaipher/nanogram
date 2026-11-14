public import Foundation

public enum GlanceActivityPolicy {
    /// "Live Location" or "Live Location · Anna": the name only when the surface may show it.
    public static func headline(base: String, name: String?, showsNames: Bool) -> String {
        if showsNames, let name, !name.isEmpty {
            return "\(base) · \(name)"
        }
        return base
    }

    /// When iOS should mark the activity out of date if the app is killed before it can end it: the sharing end,
    /// else `fallback` seconds from now (never in the past, never beyond the fallback).
    public static func staleDate(expiresAt: Date?, now: Date, fallback: TimeInterval) -> Date {
        let limit = now.addingTimeInterval(fallback)
        guard let expiresAt else {
            return limit
        }
        if expiresAt <= now {
            return now.addingTimeInterval(60.0)
        }
        return min(expiresAt, limit)
    }
}

public enum GlanceActivityKind: String, Codable, Hashable, Sendable {
    case liveLocation
    case call
}

/// What a Live Activity shows, composed by the app. Equality is the content: the stale date (recomputed from the clock
/// on every emission) and a start time that is not a real one (a connecting call) do not count, so an unchanged
/// activity is not updated again.
public struct GlanceActivityRequest: Equatable, Sendable {
    public var kind: GlanceActivityKind
    public var accountId: Int64
    public var peerId: Int64
    public var stopLabel: String
    public var headline: String
    public var status: String
    public var startedAt: Date
    public var endsAt: Date?
    public var staleDate: Date
    /// False while `startedAt` is only "now" (a call that is still connecting).
    public var isTimerLive: Bool
    /// "<accountId>:<peerId>" of every chat the activity stands for, so Stop can end all of them.
    public var chatKeys: [String]

    public init(kind: GlanceActivityKind, accountId: Int64, peerId: Int64, stopLabel: String, headline: String, status: String, startedAt: Date, endsAt: Date?, staleDate: Date, isTimerLive: Bool = true, chatKeys: [String] = []) {
        self.kind = kind
        self.accountId = accountId
        self.peerId = peerId
        self.stopLabel = stopLabel
        self.headline = headline
        self.status = status
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.staleDate = staleDate
        self.isTimerLive = isTimerLive
        self.chatKeys = chatKeys
    }

    public static func == (lhs: GlanceActivityRequest, rhs: GlanceActivityRequest) -> Bool {
        return lhs.kind == rhs.kind
            && lhs.accountId == rhs.accountId
            && lhs.peerId == rhs.peerId
            && lhs.stopLabel == rhs.stopLabel
            && lhs.headline == rhs.headline
            && lhs.status == rhs.status
            && lhs.endsAt == rhs.endsAt
            && lhs.isTimerLive == rhs.isTimerLive
            && lhs.chatKeys == rhs.chatKeys
            && (!lhs.isTimerLive || lhs.startedAt == rhs.startedAt)
    }
}

#if canImport(ActivityKit) && os(iOS)
public import ActivityKit

/// Live Activity of live-location sharing or a call that has no CallKit screen. The app composes every string, so
/// the extension never decides what may be shown.
@available(iOS 16.1, *)
public struct NanogramGlanceActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var headline: String
        public var status: String
        public var startedAt: Date
        public var endsAt: Date?

        public init(headline: String, status: String, startedAt: Date, endsAt: Date?) {
            self.headline = headline
            self.status = status
            self.startedAt = startedAt
            self.endsAt = endsAt
        }
    }

    public var kind: GlanceActivityKind
    public var accountId: Int64
    public var peerId: Int64
    public var stopLabel: String

    public init(kind: GlanceActivityKind, accountId: Int64, peerId: Int64, stopLabel: String) {
        self.kind = kind
        self.accountId = accountId
        self.peerId = peerId
        self.stopLabel = stopLabel
    }
}
#endif
