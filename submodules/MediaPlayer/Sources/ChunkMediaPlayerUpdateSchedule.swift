import Foundation

/// How often `ChunkMediaPlayerV2` re-evaluates its state from a timer. The timer wakes the main thread, so it
/// runs only as often as the state needs: events (play, pause, seek, new parts, audio session changes) call the
/// update directly, and the timer only keeps the clock-driven parts moving (status, buffering, end of video).
enum ChunkMediaPlayerUpdateSchedule {
    static let frameInterval: Double = 1.0 / 60.0
    static let steadyPlaybackInterval: Double = 1.0 / 10.0
    static let bufferingPausedInterval: Double = 1.0 / 5.0

    /// The timer interval for a state, or nil when no timer is needed.
    static func interval(isPlaying: Bool, pendingSeek: Bool, didSeekOnce: Bool, isBuffering: Bool, isStarved: Bool, isNearEnd: Bool) -> Double? {
        if pendingSeek || !didSeekOnce {
            return ChunkMediaPlayerUpdateSchedule.frameInterval
        }
        if isPlaying {
            if isBuffering || isStarved || isNearEnd {
                return ChunkMediaPlayerUpdateSchedule.frameInterval
            }
            return ChunkMediaPlayerUpdateSchedule.steadyPlaybackInterval
        }
        if isBuffering {
            return ChunkMediaPlayerUpdateSchedule.bufferingPausedInterval
        }
        return nil
    }

    /// At least 10 % of the interval and at least 2 ms, so the system can coalesce the wake-up with others.
    static func tolerance(for interval: Double) -> Double {
        return max(interval * 0.1, 0.002)
    }
}
