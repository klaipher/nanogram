import Foundation
import CoreGraphics

/// Auto-scroll while drag-selecting near the chat list's top or bottom edge. The step is 15 pt per
/// 60 fps frame at full speed, scaled by the tick's real duration so the speed is the same at any
/// display rate. The selection under the finger is refreshed 30 times a second, as before.
struct ChatListSelectionAutoScroll {
    private var previousTickTime: Double?
    private var previousSelectionUpdateTime: Double?

    /// The next tick counts as one 60 fps frame (the link was paused).
    mutating func pause() {
        self.previousTickTime = nil
    }

    mutating func tick(delta: CGFloat, now: Double) -> (distance: CGFloat, updatesSelection: Bool) {
        var frames = 1.0
        if let previousTickTime = self.previousTickTime {
            // Capped so a stalled frame does not jump.
            frames = min(2.0, max(0.0, now - previousTickTime) * 60.0)
        }
        self.previousTickTime = now
        let distance = 15.0 * min(1.0, 0.15 + abs(delta * delta)) * CGFloat(frames)

        var updatesSelection = true
        if let previousSelectionUpdateTime = self.previousSelectionUpdateTime {
            // Every other 60 fps frame; the margin absorbs timestamp jitter.
            updatesSelection = now - previousSelectionUpdateTime >= 1.0 / 30.0 - 0.002
        }
        if updatesSelection {
            self.previousSelectionUpdateTime = now
        }
        return (distance, updatesSelection)
    }
}
