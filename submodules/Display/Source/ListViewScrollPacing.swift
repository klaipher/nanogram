import Foundation
import UIKit
import QuartzCore

/// Debug Settings ▸ "List scroll: log frame rate" (off by default): how often a list's scroll view reported a new
/// offset while the user dragged it and while it decelerated. UIKit calls `scrollViewDidScroll` once per displayed
/// frame while the offset changes, so the rate of those calls is the scroll's frame rate. One log line per scroll
/// gesture, with the list's type and the A/B switches that were on.
///
/// The two phases are counted apart. While the finger drags, ProMotion runs at the screen's top rate, so an interval
/// longer than 1.5 frames is a dropped frame ("late"). After the finger lifts, ProMotion lowers the rate on purpose as
/// the fling slows (120, 80, 60 … 20 Hz), so slow frames there are expected; only a sudden stall counts ("jumps": an
/// interval longer than two frames and 2.5 times the one before it).
public final class ListViewScrollPacing {
    /// Set by the app from Debug Settings. Read on the main thread.
    public static var isEnabled: Bool = false
    /// Receives the log lines. Set by the app (to its logger).
    public static var log: ((String) -> Void)?
    /// The A/B switch state, appended to each line as ` ab=…`. Set by the app.
    public static var context: (() -> String)?

    private let listName: String
    private var drag = DisplayLinkPacingStats()
    private var deceleration = DecelerationStats()
    private var isDecelerating: Bool = false
    private var isActive: Bool = false
    private var startTime: Double = 0.0
    private var lastTimestamp: Double?

    /// A gap longer than this is a finger resting on the list, not a dropped frame.
    static let pauseThreshold: Double = 0.1

    public init(listName: String) {
        self.listName = listName
    }

    public func beginGesture(timestamp: Double) {
        guard ListViewScrollPacing.isEnabled else {
            self.isActive = false
            return
        }
        self.drag = DisplayLinkPacingStats()
        self.deceleration = DecelerationStats()
        self.isDecelerating = false
        self.isActive = true
        self.startTime = timestamp
        self.lastTimestamp = nil
    }

    public func didScroll(timestamp: Double, maximumFramesPerSecond: Int) {
        guard self.isActive else {
            return
        }
        let frameDuration = 1.0 / Double(max(1, maximumFramesPerSecond))
        if self.isDecelerating {
            if let lastTimestamp = self.lastTimestamp {
                self.deceleration.record(interval: timestamp - lastTimestamp, frameDuration: frameDuration)
            }
        } else {
            if let lastTimestamp = self.lastTimestamp, timestamp - lastTimestamp > ListViewScrollPacing.pauseThreshold {
                self.drag.pause()
            }
            self.drag.record(timestamp: timestamp, frameDuration: frameDuration)
        }
        self.lastTimestamp = timestamp
    }

    /// The finger lifted. With `willDecelerate`, the next frames belong to the deceleration.
    public func endDragging(timestamp: Double, willDecelerate: Bool) {
        guard self.isActive else {
            return
        }
        self.isDecelerating = willDecelerate
    }

    /// The gesture ended (no deceleration, or deceleration finished). Returns the logged line, nil if nothing was
    /// recorded.
    @discardableResult
    public func endGesture(timestamp: Double) -> String? {
        guard self.isActive else {
            return nil
        }
        self.isActive = false
        guard var line = ListViewScrollPacing.summary(listName: self.listName, drag: self.drag, deceleration: self.deceleration, duration: timestamp - self.startTime) else {
            return nil
        }
        if let context = ListViewScrollPacing.context?() {
            line += " ab=" + context
        }
        ListViewScrollPacing.log?(line)
        return line
    }

    static func summary(listName: String, drag: DisplayLinkPacingStats, deceleration: DecelerationStats, duration: Double) -> String? {
        guard drag.frames + deceleration.frames > 0 else {
            return nil
        }
        let dragPart: String
        if drag.frames > 0 && drag.elapsed > 0.0 {
            let latePercent = Double(drag.lateFrames) * 100.0 / Double(drag.frames)
            dragPart = String(format: "drag(frames=%d seconds=%.2f avgHz=%.1f late=%d (%.1f%%) longestMs=%.1f)", drag.frames, drag.elapsed, Double(drag.frames) / drag.elapsed, drag.lateFrames, latePercent, drag.longestInterval * 1000.0)
        } else {
            dragPart = "drag(none)"
        }
        let decelerationPart: String
        if deceleration.frames > 0 && deceleration.elapsed > 0.0 {
            decelerationPart = String(format: "decel(frames=%d seconds=%.2f avgHz=%.1f jumps=%d longestMs=%.1f)", deceleration.frames, deceleration.elapsed, Double(deceleration.frames) / deceleration.elapsed, deceleration.jumps, deceleration.longestInterval * 1000.0)
        } else {
            decelerationPart = "decel(none)"
        }
        return String(format: "ListView scroll pacing: list=%@ %@ %@ gestureSeconds=%.2f", listName, dragPart, decelerationPart, duration)
    }
}

/// Frames after the finger lifted. ProMotion steps the rate down by at most about 1.5 times per step, so an interval
/// longer than two frames and 2.5 times the previous one is a stall, not the planned slowdown.
struct DecelerationStats: Equatable {
    private(set) var frames: Int = 0
    private(set) var jumps: Int = 0
    private(set) var elapsed: Double = 0.0
    private(set) var longestInterval: Double = 0.0
    private var previousInterval: Double?

    mutating func record(interval: Double, frameDuration: Double) {
        guard interval > 0.0 else {
            return
        }
        self.frames += 1
        self.elapsed += interval
        self.longestInterval = max(self.longestInterval, interval)
        if let previousInterval = self.previousInterval, interval > frameDuration * 2.0, interval > previousInterval * 2.5 {
            self.jumps += 1
        }
        self.previousInterval = interval
    }
}
