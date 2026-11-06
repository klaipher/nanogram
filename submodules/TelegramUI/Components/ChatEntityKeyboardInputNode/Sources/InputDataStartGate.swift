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

    /// Seconds a chat stays open before the data is built without any demand.
    public static let idleDelay: Double = 4.0

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
