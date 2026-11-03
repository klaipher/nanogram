import XCTest
@testable import UniversalMediaPlayer

// On a first play the player reports `.playing` before the audio renderer has started its clock
// (the audio session is still activating, reportRate 0) with the position frozen at the start. If
// that status says "extrapolate from now", the voice waveform runs ahead of the silent player and
// clamps at the end: the whole waveform is drawn as played and stops moving until the next status.
final class MediaPlayerStatusGenerationTests: XCTestCase {
    // The voice waveform's progress (AudioWaveformComponent.draw), the time label and the scrubber
    // use the same position estimate.
    private func displayedProgress(_ status: MediaPlayerStatus, at now: Double) -> Double {
        var isPlaying = false
        if case .playing = status.status {
            isPlaying = true
        }
        let position: Double
        if status.generationTimestamp.isZero || !isPlaying {
            position = status.timestamp
        } else {
            position = status.timestamp + (now - status.generationTimestamp) * status.baseRate
        }
        return max(0.0, min(1.0, position / status.duration))
    }

    private func status(_ playbackStatus: MediaPlayerPlaybackStatus, reportRate: Double, timestamp: Double, duration: Double, now: Double) -> MediaPlayerStatus {
        let generationTimestamp = mediaPlayerStatusGenerationTimestamp(status: playbackStatus, reportRate: reportRate, now: now)
        return MediaPlayerStatus(generationTimestamp: generationTimestamp, duration: duration, dimensions: CGSize(), timestamp: timestamp, baseRate: 1.0, seekId: 0, status: playbackStatus, soundEnabled: true)
    }

    func testPlayingBeforeTheAudioClockRunsDoesNotRunAhead() {
        let tapTime = 1000.0
        // Playing, but the audio timebase rate is still 0: the session has not activated yet.
        let waiting = self.status(.playing, reportRate: 0.0, timestamp: 0.0, duration: 3.0, now: tapTime)

        XCTAssertEqual(waiting.generationTimestamp, 0.0)
        // Five seconds of a silent player later the waveform must still be at the start, not full.
        XCTAssertEqual(self.displayedProgress(waiting, at: tapTime + 5.0), 0.0, accuracy: 0.0001)
    }

    func testPlayingWithTheAudioClockRunningExtrapolates() {
        let startTime = 1000.0
        let running = self.status(.playing, reportRate: 1.0, timestamp: 0.5, duration: 4.0, now: startTime)

        XCTAssertEqual(running.generationTimestamp, startTime)
        XCTAssertEqual(self.displayedProgress(running, at: startTime + 1.5), 0.5, accuracy: 0.0001)
    }

    func testPausedAndBufferingKeepTheirTimestamp() {
        let now = 1000.0
        XCTAssertEqual(mediaPlayerStatusGenerationTimestamp(status: .paused, reportRate: 0.0, now: now), now)
        XCTAssertEqual(mediaPlayerStatusGenerationTimestamp(status: .buffering(initial: false, whilePlaying: true, progress: 0.0, display: true), reportRate: 0.0, now: now), now)
        // A paused status is never extrapolated, whatever its generation timestamp.
        let paused = self.status(.paused, reportRate: 0.0, timestamp: 1.0, duration: 4.0, now: now)
        XCTAssertEqual(self.displayedProgress(paused, at: now + 10.0), 0.25, accuracy: 0.0001)
    }
}
