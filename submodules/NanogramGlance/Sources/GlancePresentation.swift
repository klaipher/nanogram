public import Foundation

/// The passcode lock as a widget or Live Activity sees it. Same shape as AppLockState's `AppLockSchedule`, which
/// the widget extension maps from.
public enum GlanceLockPhase: Equatable, Sendable {
    case unlocked
    case locked
    case locksIn(Int32)
}

public enum GlanceSurface: Equatable, Sendable {
    /// Home Screen widgets.
    case homeScreen
    /// Lock Screen accessories, StandBy-dimmed content, Live Activities and Control Center: anything readable
    /// without unlocking the phone.
    case lockScreen
}

public extension GlanceSurface {
    /// A small Home Screen widget is a lock-screen surface when it is shown without its container background
    /// (StandBy, iPad Lock Screen) or tinted/vibrant: it can then be read on a locked device.
    static func smallWidget(showsContainerBackground: Bool, isFullColor: Bool) -> GlanceSurface {
        return showsContainerBackground && isFullColor ? .homeScreen : .lockScreen
    }
}

public enum GlanceVisibility {
    /// Chat names show only while the app is not passcode-locked, and on the lock-screen surfaces only when the
    /// "name on lock screen" notification setting allows it. Counts are not affected.
    public static func showsNames(surface: GlanceSurface, lock: GlanceLockPhase, displayNameOnLockscreen: Bool) -> Bool {
        if lock == .locked {
            return false
        }
        switch surface {
        case .homeScreen:
            return true
        case .lockScreen:
            return displayNameOnLockscreen
        }
    }

    public static func title(name: String, genericTitle: String, showsNames: Bool) -> String {
        if showsNames && !name.isEmpty {
            return name
        }
        return genericTitle
    }
}

public struct GlanceTimelineStep: Equatable, Sendable {
    public var offsetSeconds: Int32
    public var isLocked: Bool

    public init(offsetSeconds: Int32, isLocked: Bool) {
        self.offsetSeconds = offsetSeconds
        self.isLocked = isLocked
    }
}

public enum GlanceTimeline {
    /// The widget entries to emit: as they are now, and again with the lock applied when the auto-lock runs out
    /// while the widget is on screen.
    public static func steps(lock: GlanceLockPhase) -> [GlanceTimelineStep] {
        switch lock {
        case .unlocked:
            return [GlanceTimelineStep(offsetSeconds: 0, isLocked: false)]
        case .locked:
            return [GlanceTimelineStep(offsetSeconds: 0, isLocked: true)]
        case let .locksIn(seconds):
            return [GlanceTimelineStep(offsetSeconds: 0, isLocked: false), GlanceTimelineStep(offsetSeconds: max(1, seconds), isLocked: true)]
        }
    }
}

public enum GlanceCount {
    /// Unread total of the chats shown; muted chats do not count, as in the app's badge.
    public static func total(_ counts: [(count: Int, isMuted: Bool)]) -> Int {
        var result = 0
        for item in counts where !item.isMuted && item.count > 0 {
            result += item.count
        }
        return result
    }

    public static func text(_ value: Int) -> String {
        return value > 999 ? "999+" : "\(value)"
    }
}
