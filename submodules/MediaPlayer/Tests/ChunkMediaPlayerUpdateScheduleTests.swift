import XCTest
@testable import UniversalMediaPlayer

/// The update timer of `ChunkMediaPlayerV2` is the main thread's wake-up source for every playing video: it
/// has to be as slow as the state allows, always have a tolerance so the system can coalesce it, and not run
/// at all for a settled paused player.
final class ChunkMediaPlayerUpdateScheduleTests: XCTestCase {
    private func interval(
        isPlaying: Bool = false,
        pendingSeek: Bool = false,
        didSeekOnce: Bool = true,
        isBuffering: Bool = false,
        isStarved: Bool = false,
        isNearEnd: Bool = false
    ) -> Double? {
        return ChunkMediaPlayerUpdateSchedule.interval(isPlaying: isPlaying, pendingSeek: pendingSeek, didSeekOnce: didSeekOnce, isBuffering: isBuffering, isStarved: isStarved, isNearEnd: isNearEnd)
    }

    func testSteadyPlaybackRunsAtTenHertz() {
        XCTAssertEqual(self.interval(isPlaying: true), 0.1)
    }

    func testSeekingAndTheFirstSeekRunAtTheFrameRate() {
        XCTAssertEqual(self.interval(isPlaying: true, pendingSeek: true), 1.0 / 60.0)
        XCTAssertEqual(self.interval(pendingSeek: true), 1.0 / 60.0)
        XCTAssertEqual(self.interval(didSeekOnce: false), 1.0 / 60.0)
    }

    func testPlayingWhileBufferingStarvedOrNearTheEndRunsAtTheFrameRate() {
        XCTAssertEqual(self.interval(isPlaying: true, isBuffering: true), 1.0 / 60.0)
        XCTAssertEqual(self.interval(isPlaying: true, isStarved: true), 1.0 / 60.0)
        XCTAssertEqual(self.interval(isPlaying: true, isNearEnd: true), 1.0 / 60.0)
    }

    func testASettledPausedPlayerDoesNotPoll() {
        XCTAssertNil(self.interval())
        XCTAssertNil(self.interval(isStarved: true))
        XCTAssertNil(self.interval(isNearEnd: true))
    }

    func testAPausedPlayerThatIsBufferingStillPollsSlowly() {
        XCTAssertEqual(self.interval(isBuffering: true), 0.2)
    }

    func testEveryIntervalHasATolerance() {
        for interval in [1.0 / 60.0, 0.1, 0.2] {
            let tolerance = ChunkMediaPlayerUpdateSchedule.tolerance(for: interval)
            XCTAssertGreaterThanOrEqual(tolerance, 0.002, "\(interval)")
            XCTAssertGreaterThanOrEqual(tolerance, interval * 0.1 - 0.000_000_1, "\(interval)")
            XCTAssertLessThan(tolerance, interval, "\(interval)")
        }
    }
}
