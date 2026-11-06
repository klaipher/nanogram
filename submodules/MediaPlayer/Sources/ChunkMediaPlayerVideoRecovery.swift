import Foundation

/// When `ChunkMediaPlayerV2` has to rebuild its video pipeline although the clock and the audio keep running.
///
/// A video can stop producing pictures while the sound goes on: the display layer fails or asks to be flushed after
/// the app was in the background (it ignores every enqueued frame until it is flushed), or the hardware decoder
/// session of the reader died there (the reader then yields no frames and, once it reads to the end, is marked
/// finished). Pause and play touch neither the layer nor the reader; only a seek flushes the layer and builds new
/// readers, so without this the viewer has to restart the video from zero.
struct ChunkMediaPlayerVideoRecovery {
    /// After returning to the foreground a video that plays has this long to enqueue its first frame.
    static let foregroundGrace: Double = 1.5
    /// A recovery that did not help is not repeated sooner than this.
    static let minimumInterval: Double = 4.0

    private var foregroundedAt: Double?
    private var lastRecoveryAt: Double?

    mutating func noteForeground(now: Double) {
        self.foregroundedAt = now
    }

    mutating func noteBackground() {
        self.foregroundedAt = nil
    }

    /// True when the pipeline must be rebuilt now. `lastVideoEnqueueAt` is the time the player last handed a video
    /// frame to the renderer. `isPlayingWithClock` is false for a paused, buffering, suspended or finished video,
    /// which shows no new pictures anyway.
    mutating func shouldRecover(now: Double, isApplicationInBackground: Bool, isPlayingWithClock: Bool, hasVideo: Bool, layerNeedsFlush: Bool, lastVideoEnqueueAt: Double?) -> Bool {
        if isApplicationInBackground || !isPlayingWithClock || !hasVideo {
            return false
        }
        if let lastRecoveryAt = self.lastRecoveryAt, now - lastRecoveryAt < ChunkMediaPlayerVideoRecovery.minimumInterval {
            return false
        }
        var needsRecovery = layerNeedsFlush
        if !needsRecovery, let foregroundedAt = self.foregroundedAt, now - foregroundedAt >= ChunkMediaPlayerVideoRecovery.foregroundGrace {
            let enqueuedSinceForeground = lastVideoEnqueueAt.map { $0 >= foregroundedAt } ?? false
            if enqueuedSinceForeground {
                self.foregroundedAt = nil
            } else {
                needsRecovery = true
            }
        }
        if needsRecovery {
            self.foregroundedAt = nil
            self.lastRecoveryAt = now
        }
        return needsRecovery
    }
}
