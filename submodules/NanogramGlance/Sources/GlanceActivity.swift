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

#if canImport(ActivityKit) && os(iOS)
public import ActivityKit

/// Live Activity of live-location sharing or a call that has no CallKit screen. The app composes every string, so
/// the extension never decides what may be shown.
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
