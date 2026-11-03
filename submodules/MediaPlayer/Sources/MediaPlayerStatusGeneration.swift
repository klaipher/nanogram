import Foundation

// The `generationTimestamp` a MediaPlayer status carries. Every consumer (the voice waveform, the
// bubble's time label, the scrubber) shows `timestamp + (now - generationTimestamp) * baseRate` while
// the status is `.playing`, and shows `timestamp` as is when `generationTimestamp` is 0.
//
// A `.playing` status whose clock is not running (`reportRate` 0) carries a frozen position, so it gets
// 0. That is the first play, while the audio session is still activating, and the loop at the end, where
// the player reports `.playing` at rate 0 before it seeks back to the start. Stamping the first with
// `now` made the voice waveform run ahead of the silent player and clamp at the end: the whole waveform
// drawn as played, not moving, until the next status. A consumer must never count ahead from a 0
// generation (the view-once ring once did, and ran the device uptime ahead).
func mediaPlayerStatusGenerationTimestamp(status: MediaPlayerPlaybackStatus, reportRate: Double, now: Double) -> Double {
    if case .playing = status, reportRate.isZero {
        return 0.0
    }
    return now
}
