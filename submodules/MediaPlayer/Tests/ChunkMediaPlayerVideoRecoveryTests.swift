import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

/// A round video that plays with sound is not suspended in the background, so its picture can die there while the
/// audio goes on (a failed display layer, a hardware decoder session that did not survive). Pause and play do not
/// repair that; the player has to rebuild the video pipeline by itself, once per episode, when it sees the symptom.
/// A paused, buffering or merely slow video must never get a forced seek.
final class ChunkMediaPlayerVideoRecoveryTests: XCTestCase {
    private typealias Recovery = ChunkMediaPlayerVideoRecovery

    private func check(_ recovery: inout Recovery, now: Double, background: Bool = false, playing: Bool = true, hasSentVideo: Bool = true, layer: Recovery.LayerState = .healthy, lastEnqueue: Double?, lastStarvation: Double? = nil) -> Recovery.Reason? {
        return recovery.shouldRecover(now: now, isApplicationInBackground: background, isPlayingWithClock: playing, hasSentVideo: hasSentVideo, lastVideoEnqueueAt: lastEnqueue, lastVideoStarvationAt: lastStarvation, layerState: { layer })
    }

    func testAHealthyVideoIsLeftAlone() {
        var recovery = Recovery()
        XCTAssertNil(self.check(&recovery, now: 10.0, lastEnqueue: 9.99))
    }

    func testAFailedLayerAndAFlushRequestingLayerAreRecoveredWithTheirReason() {
        var failed = Recovery()
        XCTAssertEqual(self.check(&failed, now: 10.0, layer: .failed, lastEnqueue: 9.0), .layerFailed)
        var flush = Recovery()
        XCTAssertEqual(self.check(&flush, now: 10.0, layer: .needsFlush, lastEnqueue: 9.0), .layerNeedsFlush)
    }

    func testNothingIsRecoveredInTheBackground() {
        var recovery = Recovery()
        XCTAssertNil(self.check(&recovery, now: 10.0, background: true, layer: .failed, lastEnqueue: nil))
    }

    func testPausedBufferingOrNeverSentVideoPlayersAreNotRecovered() {
        var recovery = Recovery()
        XCTAssertNil(self.check(&recovery, now: 10.0, playing: false, layer: .failed, lastEnqueue: 9.0))
        XCTAssertNil(self.check(&recovery, now: 10.0, hasSentVideo: false, layer: .failed, lastEnqueue: nil))
    }

    func testNoFrameWhileTheRendererStarvedWithinTheGraceAfterTheForegroundIsRecovered() {
        var recovery = Recovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertNil(self.check(&recovery, now: 20.0, lastEnqueue: 19.0, lastStarvation: 20.0))
        XCTAssertNil(self.check(&recovery, now: 20.5, lastEnqueue: 19.0, lastStarvation: 20.4), "the first frames may still be on their way")
        XCTAssertEqual(self.check(&recovery, now: 20.0 + Recovery.foregroundGrace, lastEnqueue: 19.0, lastStarvation: 21.0), .noFrameAfterForeground)
    }

    func testAFullLayerThatNeverAskedForFramesIsNotRecovered() {
        var recovery = Recovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertNil(self.check(&recovery, now: 20.0, lastEnqueue: 19.0, lastStarvation: nil))
        XCTAssertNil(self.check(&recovery, now: 30.0, lastEnqueue: 19.0, lastStarvation: 10.0), "a starvation from before the foreground proves nothing")
    }

    func testAFrameAfterReturningToTheForegroundCancelsTheCheck() {
        var recovery = Recovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertNil(self.check(&recovery, now: 20.0, lastEnqueue: 19.0))
        XCTAssertNil(self.check(&recovery, now: 22.0, lastEnqueue: 21.0, lastStarvation: 21.5))
        XCTAssertNil(self.check(&recovery, now: 40.0, lastEnqueue: 21.0, lastStarvation: 39.0), "a video that showed a frame is not checked again")
    }

    func testAPausedVideoThatPlaysLaterGetsNoSeek() {
        var recovery = Recovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertNil(self.check(&recovery, now: 20.0, playing: false, lastEnqueue: 19.0))
        XCTAssertNil(self.check(&recovery, now: 25.0, playing: false, lastEnqueue: 19.0))
        // Play at 30.0: the layer is full, so the renderer neither enqueues nor starves, however long ago the foreground was.
        XCTAssertNil(self.check(&recovery, now: 30.0, lastEnqueue: 19.0))
        XCTAssertNil(self.check(&recovery, now: 30.0 + Recovery.foregroundGrace, lastEnqueue: 19.0))
        XCTAssertNil(self.check(&recovery, now: 40.0, lastEnqueue: 19.0))
    }

    func testAPausedVideoThatPlaysAndStarvesIsRecoveredOnlyAfterTheGraceFromPlay() {
        var recovery = Recovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertNil(self.check(&recovery, now: 25.0, playing: false, lastEnqueue: 19.0))
        XCTAssertNil(self.check(&recovery, now: 30.0, lastEnqueue: 19.0, lastStarvation: 30.0))
        XCTAssertNil(self.check(&recovery, now: 31.0, lastEnqueue: 19.0, lastStarvation: 31.0))
        XCTAssertEqual(self.check(&recovery, now: 30.0 + Recovery.foregroundGrace, lastEnqueue: 19.0, lastStarvation: 31.5), .noFrameAfterForeground)
    }

    func testABufferingVideoGetsNoSeekAndTheGraceRestartsWhenItPlaysAgain() {
        var recovery = Recovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertNil(self.check(&recovery, now: 20.0, lastEnqueue: 19.0))
        // Buffering for 5 s after the return: the clock is stopped, the reader has no data.
        XCTAssertNil(self.check(&recovery, now: 22.0, playing: false, lastEnqueue: 19.0, lastStarvation: 22.0))
        XCTAssertNil(self.check(&recovery, now: 25.0, playing: false, lastEnqueue: 19.0, lastStarvation: 25.0))
        // Data arrives and the clock restarts at 25.0; frames follow within the grace.
        XCTAssertNil(self.check(&recovery, now: 25.0, lastEnqueue: 19.0, lastStarvation: 25.0))
        XCTAssertNil(self.check(&recovery, now: 25.5, lastEnqueue: 25.2, lastStarvation: 25.0))
        XCTAssertNil(self.check(&recovery, now: 40.0, lastEnqueue: 39.9))
    }

    func testEnteringTheBackgroundDisarmsTheCheck() {
        var recovery = Recovery()
        recovery.noteForeground(now: 20.0)
        recovery.noteBackground()
        XCTAssertNil(self.check(&recovery, now: 30.0, lastEnqueue: 19.0, lastStarvation: 29.0))
    }

    func testALayerThatKeepsFailingIsRecoveredOncePerForegroundEpisode() {
        var recovery = Recovery()
        XCTAssertEqual(self.check(&recovery, now: 10.0, layer: .failed, lastEnqueue: nil), .layerFailed)
        for tick in 1...50 {
            XCTAssertNil(self.check(&recovery, now: 10.0 + Double(tick) * 4.0, layer: .failed, lastEnqueue: nil))
        }
        recovery.noteForeground(now: 300.0)
        XCTAssertEqual(self.check(&recovery, now: 300.0, layer: .failed, lastEnqueue: nil), .layerFailed, "a new return to the foreground is a new episode")
        XCTAssertNil(self.check(&recovery, now: 310.0, layer: .failed, lastEnqueue: nil))
    }

    func testAUserSeekStartsANewEpisode() {
        var recovery = Recovery()
        XCTAssertEqual(self.check(&recovery, now: 10.0, layer: .needsFlush, lastEnqueue: nil), .layerNeedsFlush)
        XCTAssertNil(self.check(&recovery, now: 20.0, layer: .needsFlush, lastEnqueue: nil))
        recovery.noteUserSeek()
        XCTAssertEqual(self.check(&recovery, now: 21.0, layer: .needsFlush, lastEnqueue: nil), .layerNeedsFlush)
    }

    func testTheLayerIsOnlyReadWhenARecoveryIsPossible() {
        var recovery = Recovery()
        var reads = 0
        func read(playing: Bool, background: Bool) {
            let _ = recovery.shouldRecover(now: 10.0, isApplicationInBackground: background, isPlayingWithClock: playing, hasSentVideo: true, lastVideoEnqueueAt: 9.0, lastVideoStarvationAt: nil, layerState: { reads += 1; return .healthy })
        }
        read(playing: false, background: false)
        read(playing: true, background: true)
        XCTAssertEqual(reads, 0)
        read(playing: true, background: false)
        XCTAssertEqual(reads, 1)
    }
}
