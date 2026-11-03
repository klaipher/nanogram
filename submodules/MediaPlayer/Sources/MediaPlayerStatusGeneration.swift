import Foundation

// The `generationTimestamp` a MediaPlayer status carries. Every consumer (the voice waveform, the
// bubble's time label, the scrubber) shows `timestamp + (now - generationTimestamp) * baseRate` while
// the status is `.playing`, and shows `timestamp` as is when `generationTimestamp` is 0.
//
// A `.playing` status whose audio clock is not running yet (`reportRate` 0: the audio session is
// still activating, typically on the first play) carries a frozen position, so it gets 0. Stamping it
// with `now` made the voice waveform run ahead of the silent player and clamp at the end: the whole
// waveform drawn as played, not moving, until the next status.
func mediaPlayerStatusGenerationTimestamp(status: MediaPlayerPlaybackStatus, reportRate: Double, now: Double) -> Double {
    if case .playing = status, reportRate.isZero {
        return 0.0
    }
    return now
}
