import Foundation

/// When `ChunkMediaPlayerV2` has to rebuild its video pipeline although the clock and the audio keep running.
///
/// A video can stop producing pictures while the sound goes on: the display layer fails or asks to be flushed after
/// the app was in the background (it ignores every enqueued frame until it is flushed), or the hardware decoder
/// session of the reader died there (the reader then yields no frames and, once it reads to the end, is marked
/// finished). Pause and play touch neither the layer nor the reader; only a seek flushes the layer and builds new
/// readers, so without this the viewer has to restart the video from zero.
///
/// The rebuild is a forced seek, so it is only done on evidence: the layer reports a failure, or the video renderer
/// asked for frames while the clock was running and the reader had none. A paused or buffering video, or one whose
/// layer is simply full, never counts. At most one rebuild per return to the foreground and per user seek.
struct ChunkMediaPlayerVideoRecovery {
    enum LayerState {
        case healthy
        case failed
        case needsFlush
    }

    enum Reason: String {
        case layerFailed
        case layerNeedsFlush
        case noFrameAfterForeground
    }

    /// After returning to the foreground, a video whose clock runs has this long to enqueue its first frame.
    static let foregroundGrace: Double = 1.5
    /// A recovery that did not help is not repeated sooner than this.
    static let minimumInterval: Double = 4.0
    /// Recoveries allowed per return to the foreground and per user seek.
    static let maximumAttempts: Int = 1

    private var foregroundedAt: Double?
    private var playingSince: Double?
    private var lastRecoveryAt: Double?
    private var attempts: Int = 0

    mutating func noteForeground(now: Double) {
        self.foregroundedAt = now
        self.playingSince = nil
        self.attempts = 0
    }

    mutating func noteBackground() {
        self.foregroundedAt = nil
    }

    /// A seek by the user starts a new episode.
    mutating func noteUserSeek() {
        self.attempts = 0
        self.playingSince = nil
    }

    /// The reason to rebuild the pipeline now, if any. `lastVideoEnqueueAt` is the time the player last handed a
    /// video frame to the renderer, `lastVideoStarvationAt` the time the renderer last wanted a frame and the reader
    /// had none. `isPlayingWithClock` is false for a paused, buffering, suspended or finished video.
    /// `layerState` is read only when everything cheaper allows a recovery.
    mutating func shouldRecover(now: Double, isApplicationInBackground: Bool, isPlayingWithClock: Bool, hasSentVideo: Bool, lastVideoEnqueueAt: Double?, lastVideoStarvationAt: Double?, layerState: () -> LayerState) -> Reason? {
        if !isPlayingWithClock {
            self.playingSince = nil
            return nil
        }
        if self.playingSince == nil {
            self.playingSince = now
        }
        if isApplicationInBackground || !hasSentVideo || self.attempts >= ChunkMediaPlayerVideoRecovery.maximumAttempts {
            return nil
        }
        if let lastRecoveryAt = self.lastRecoveryAt, now - lastRecoveryAt < ChunkMediaPlayerVideoRecovery.minimumInterval {
            return nil
        }
        var reason: Reason?
        switch layerState() {
        case .failed:
            reason = .layerFailed
        case .needsFlush:
            reason = .layerNeedsFlush
        case .healthy:
            if let foregroundedAt = self.foregroundedAt, let playingSince = self.playingSince {
                let anchor = max(foregroundedAt, playingSince)
                if (lastVideoEnqueueAt ?? -Double.infinity) >= anchor {
                    self.foregroundedAt = nil
                } else if now - anchor >= ChunkMediaPlayerVideoRecovery.foregroundGrace, let lastVideoStarvationAt, lastVideoStarvationAt >= anchor {
                    reason = .noFrameAfterForeground
                }
            }
        }
        if reason != nil {
            self.foregroundedAt = nil
            self.lastRecoveryAt = now
            self.attempts += 1
        }
        return reason
    }
}
