import Foundation
import UIKit
import QuartzCore

/// Debug Settings ▸ "List scroll: log frame rate" (off by default): how often a list's scroll view reported a new
/// offset while the user dragged it or it decelerated. UIKit calls `scrollViewDidScroll` once per displayed frame
/// while the offset changes, so the rate of those calls is the scroll's frame rate. One log line per scroll gesture
/// (drag plus deceleration), with the list's type, so the chat list can be told from other lists.
public final class ListViewScrollPacing {
    /// Set by the app from Debug Settings. Read on the main thread.
    public static var isEnabled: Bool = false
    /// Receives the log lines. Set by the app (to its logger).
    public static var log: ((String) -> Void)?

    private let listName: String
    private var stats = DisplayLinkPacingStats()
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
        self.stats = DisplayLinkPacingStats()
        self.isActive = true
        self.startTime = timestamp
        self.lastTimestamp = nil
    }

    public func didScroll(timestamp: Double, maximumFramesPerSecond: Int) {
        guard self.isActive else {
            return
        }
        if let lastTimestamp = self.lastTimestamp, timestamp - lastTimestamp > ListViewScrollPacing.pauseThreshold {
            self.stats.pause()
        }
        self.lastTimestamp = timestamp
        self.stats.record(timestamp: timestamp, frameDuration: 1.0 / Double(max(1, maximumFramesPerSecond)))
    }

    /// The gesture ended (no deceleration, or deceleration finished). Returns the logged line, nil if nothing was
    /// recorded.
    @discardableResult
    public func endGesture(timestamp: Double) -> String? {
        guard self.isActive else {
            return nil
        }
        self.isActive = false
        guard let line = ListViewScrollPacing.summary(listName: self.listName, stats: self.stats, duration: timestamp - self.startTime) else {
            return nil
        }
        ListViewScrollPacing.log?(line)
        return line
    }

    static func summary(listName: String, stats: DisplayLinkPacingStats, duration: Double) -> String? {
        guard stats.frames > 0, stats.elapsed > 0.0 else {
            return nil
        }
        let averageHz = Double(stats.frames) / stats.elapsed
        let latePercent = Double(stats.lateFrames) * 100.0 / Double(stats.frames)
        return String(format: "ListView scroll pacing: list=%@ frames=%d seconds=%.2f avgHz=%.1f late=%d (%.1f%%) longestMs=%.1f gestureSeconds=%.2f", listName, stats.frames, stats.elapsed, averageHz, stats.lateFrames, latePercent, stats.longestInterval * 1000.0, duration)
    }
}
