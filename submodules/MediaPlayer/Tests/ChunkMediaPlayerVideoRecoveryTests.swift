import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

/// A round video that plays with sound is not suspended in the background, so its picture can die there while the
/// audio goes on (a failed display layer, a hardware decoder session that did not survive). Pause and play do not
/// repair that; the player has to rebuild the video pipeline by itself once, when it sees the symptom.
final class ChunkMediaPlayerVideoRecoveryTests: XCTestCase {
    private func recover(_ recovery: inout ChunkMediaPlayerVideoRecovery, now: Double, background: Bool = false, playing: Bool = true, hasVideo: Bool = true, layerNeedsFlush: Bool = false, lastEnqueue: Double?) -> Bool {
        return recovery.shouldRecover(now: now, isApplicationInBackground: background, isPlayingWithClock: playing, hasVideo: hasVideo, layerNeedsFlush: layerNeedsFlush, lastVideoEnqueueAt: lastEnqueue)
    }

    func testAHealthyVideoIsLeftAlone() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        XCTAssertFalse(self.recover(&recovery, now: 10.0, lastEnqueue: 9.99))
    }

    func testAFlushRequestingLayerIsRecoveredInTheForeground() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        XCTAssertTrue(self.recover(&recovery, now: 10.0, layerNeedsFlush: true, lastEnqueue: 9.0))
    }

    func testNothingIsRecoveredInTheBackground() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        XCTAssertFalse(self.recover(&recovery, now: 10.0, background: true, layerNeedsFlush: true, lastEnqueue: nil))
    }

    func testPausedBufferingOrVideolessPlayersAreNotRecovered() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        XCTAssertFalse(self.recover(&recovery, now: 10.0, playing: false, layerNeedsFlush: true, lastEnqueue: nil))
        XCTAssertFalse(self.recover(&recovery, now: 10.0, hasVideo: false, layerNeedsFlush: true, lastEnqueue: nil))
    }

    func testNoFrameWithinTheGraceAfterReturningToTheForegroundIsRecovered() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertFalse(self.recover(&recovery, now: 20.5, lastEnqueue: 19.0), "the first frames may still be on their way")
        XCTAssertTrue(self.recover(&recovery, now: 20.0 + ChunkMediaPlayerVideoRecovery.foregroundGrace, lastEnqueue: 19.0))
    }

    func testAFrameAfterReturningToTheForegroundCancelsTheCheck() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertFalse(self.recover(&recovery, now: 22.0, lastEnqueue: 21.0))
        XCTAssertFalse(self.recover(&recovery, now: 40.0, lastEnqueue: 21.0), "a video that showed a frame is not checked again")
    }

    func testAPausedVideoIsNotRecoveredAndTheCheckSurvivesUntilItPlays() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        recovery.noteForeground(now: 20.0)
        XCTAssertFalse(self.recover(&recovery, now: 25.0, playing: false, lastEnqueue: 19.0))
        XCTAssertTrue(self.recover(&recovery, now: 26.0, lastEnqueue: 19.0))
    }

    func testEnteringTheBackgroundDisarmsTheCheck() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        recovery.noteForeground(now: 20.0)
        recovery.noteBackground()
        XCTAssertFalse(self.recover(&recovery, now: 30.0, lastEnqueue: 19.0))
    }

    func testARecoveryIsNotRepeatedBeforeTheMinimumInterval() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        XCTAssertTrue(self.recover(&recovery, now: 10.0, layerNeedsFlush: true, lastEnqueue: nil))
        XCTAssertFalse(self.recover(&recovery, now: 12.0, layerNeedsFlush: true, lastEnqueue: nil))
        XCTAssertTrue(self.recover(&recovery, now: 10.0 + ChunkMediaPlayerVideoRecovery.minimumInterval, layerNeedsFlush: true, lastEnqueue: nil))
    }

    func testAForegroundedVideoThatNeverEnqueuedIsRecoveredOnce() {
        var recovery = ChunkMediaPlayerVideoRecovery()
        recovery.noteForeground(now: 5.0)
        XCTAssertTrue(self.recover(&recovery, now: 7.0, lastEnqueue: nil))
        XCTAssertFalse(self.recover(&recovery, now: 9.0, lastEnqueue: nil))
    }
}
