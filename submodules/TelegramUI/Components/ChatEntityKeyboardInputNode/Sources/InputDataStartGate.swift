import Foundation

/// Decides when a chat builds its emoji and sticker panel data. Building it on every chat open cost
/// about 250 ms of CPU per 30 s (132 ms item setup, 116 ms featured-pack decode) even when the panel
/// was never opened, and ran inside the chat-open window. The build now starts on first demand
/// (the panel is about to open), on a prewarm signal (touch-down on the panel button, input focus) or once the chat has been idle for `idleDelay`, and only once.
public struct InputDataStartGate {
    public enum Trigger: Equatable {
        /// The panel, or a screen that needs its data, was requested.
        case demand
        /// The chat stayed open long enough to build the data in the background.
        case idle
        /// The user is about to open the panel: the panel button was touched down, or the text input got
        /// focus (the keyboard is rising, and the panel button is usually next). The build then overlaps
        /// the keyboard animation instead of the panel's own open.
        case prewarm
    }

    /// Seconds after the chat's panels were loaded (the push transition takes ~0.35 s) before the data is built
    /// without any demand. Short, so a panel opened without a touch-down or focus signal first is not slower than
    /// when the data was built at chat open; long enough to stay out of the chat-open window.
    public static let idleDelay: Double = 0.5
    /// The idle build waits until the history list has not scrolled for this long, and asks again after the same time.
    public static let scrollQuietPeriod: Double = 0.3

    /// Seconds the build waits after the text input got focus: about the keyboard's own animation (0.25 s plus slack), so
    /// the main-thread build does not land in the keyboard's frames. A touch-down on the panel button is not delayed.
    public static let focusPrewarmWait: Double = 0.4

    public enum IdleDecision: Equatable {
        case startNow
        case retry(after: Double)
    }

    /// The idle build also waits until the text has not changed for this long. The build is ~250 ms on the main thread,
    /// and on iOS 27 the system keyboard's key repeat runs on our main thread too: a build landing in a held delete right
    /// after focus stalled the repeat (one character per hold, owner's tester, 2026-11-08).
    public static let typingQuietPeriod: Double = 0.5

    /// Whether the idle build may start now, given the seconds since the history list last scrolled and since the text
    /// last changed (nil: it has not).
    public static func idleDecision(secondsSinceLastScroll: Double?, secondsSinceLastTextChange: Double? = nil) -> IdleDecision {
        var wait: Double = 0.0
        if let secondsSinceLastScroll, secondsSinceLastScroll < scrollQuietPeriod {
            wait = max(wait, scrollQuietPeriod - max(0.0, secondsSinceLastScroll))
        }
        if let secondsSinceLastTextChange, secondsSinceLastTextChange < typingQuietPeriod {
            wait = max(wait, typingQuietPeriod - max(0.0, secondsSinceLastTextChange))
        }
        if wait > 0.0 {
            return .retry(after: wait)
        }
        return .startNow
    }

    public private(set) var hasStarted = false

    public init() {
    }

    /// True exactly once: for the first trigger.
    public mutating func shouldStart(_ trigger: Trigger) -> Bool {
        if self.hasStarted {
            return false
        }
        self.hasStarted = true
        return true
    }
}
