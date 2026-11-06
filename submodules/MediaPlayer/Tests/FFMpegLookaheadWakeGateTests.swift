import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

/// Every playing player used to wake its lookahead thread ten times a second, whether or not the buffer needed
/// anything. The gate sends a wake-up only when the readable range has fallen behind the position.
final class FFMpegLookaheadWakeGateTests: XCTestCase {
    private let lookahead = 10.0

    private func wake(_ gate: FFMpegLookaheadWakeGate, position: Double, seekTo: Double = 0.0) -> Bool {
        return gate.shouldWake(position: position, seekTo: seekTo, lookaheadDuration: self.lookahead)
    }

    func testTheFirstUpdateWakesBecauseNothingHasBeenRead() {
        let gate = FFMpegLookaheadWakeGate()
        XCTAssertTrue(self.wake(gate, position: 0.0))
    }

    func testAFullBufferIsLeftAlone() {
        let gate = FFMpegLookaheadWakeGate()
        gate.noteProgress(readableTo: 10.2, isEnded: false)
        var wakeCount = 0
        for step in 0 ..< 15 {
            if self.wake(gate, position: Double(step) * 0.1) {
                wakeCount += 1
            }
        }
        XCTAssertEqual(wakeCount, 0)
    }

    func testTheBufferIsToppedUpOnceItHasShrunkByTheMargin() {
        let gate = FFMpegLookaheadWakeGate()
        gate.noteProgress(readableTo: 10.0, isEnded: false)
        XCTAssertFalse(self.wake(gate, position: 1.9))
        XCTAssertTrue(self.wake(gate, position: 2.1))
    }

    func testOnlyOneWakeIsQueuedUntilTheThreadHandlesIt() {
        let gate = FFMpegLookaheadWakeGate()
        gate.noteProgress(readableTo: 10.0, isEnded: false)
        XCTAssertTrue(self.wake(gate, position: 3.0))
        XCTAssertFalse(self.wake(gate, position: 3.1))
        XCTAssertFalse(self.wake(gate, position: 3.2))
        gate.beginWake()
        XCTAssertTrue(self.wake(gate, position: 3.3))
    }

    func testAWakeAfterTheThreadStartedHandlingIsNotLost() {
        let gate = FFMpegLookaheadWakeGate()
        gate.noteProgress(readableTo: 10.0, isEnded: false)
        XCTAssertTrue(self.wake(gate, position: 3.0))
        gate.beginWake()
        XCTAssertTrue(self.wake(gate, position: 3.1))
    }

    func testNothingWakesAfterTheFileEnded() {
        let gate = FFMpegLookaheadWakeGate()
        gate.noteProgress(readableTo: 4.0, isEnded: true)
        XCTAssertFalse(self.wake(gate, position: 3.0))
    }

    func testAStreamThatHasNotProducedPacketsKeepsWaking() {
        let gate = FFMpegLookaheadWakeGate()
        gate.noteProgress(readableTo: nil, isEnded: false)
        XCTAssertTrue(self.wake(gate, position: 0.0))
        gate.beginWake()
        XCTAssertTrue(self.wake(gate, position: 0.1))
    }

    func testTheSeekPositionCountsWhenThePlayerIsStillBehindIt() {
        let gate = FFMpegLookaheadWakeGate()
        gate.noteProgress(readableTo: 14.0, isEnded: false)
        XCTAssertFalse(self.wake(gate, position: 0.0, seekTo: 5.0))
        XCTAssertTrue(self.wake(gate, position: 0.0, seekTo: 7.0))
    }

    func testTheMarginNeverExceedsAQuarterOfAShortLookahead() {
        XCTAssertEqual(FFMpegLookaheadWakeGate.refillMargin(lookaheadDuration: 10.0), 2.0)
        XCTAssertEqual(FFMpegLookaheadWakeGate.refillMargin(lookaheadDuration: 4.0), 1.0)
        XCTAssertEqual(FFMpegLookaheadWakeGate.refillMargin(lookaheadDuration: 0.0), 0.0)
        XCTAssertEqual(FFMpegLookaheadWakeGate.refillMargin(lookaheadDuration: -1.0), 0.0)
    }

    func testTheBufferNeverRunsBelowEightSecondsAheadWithTheDefaultLookahead() {
        for position in stride(from: 0.0, through: 30.0, by: 0.1) {
            let gate = FFMpegLookaheadWakeGate()
            gate.noteProgress(readableTo: position + 10.0, isEnded: false)
            var minimumAhead = 10.0
            var readable = position + 10.0
            var clock = position
            while clock < position + 20.0 {
                if self.wake(gate, position: clock) {
                    readable = max(readable, clock + 10.0)
                    gate.noteProgress(readableTo: readable, isEnded: false)
                    gate.beginWake()
                }
                minimumAhead = min(minimumAhead, readable - clock)
                clock += 0.1
            }
            XCTAssertGreaterThanOrEqual(minimumAhead, 7.9, "\(position)")
        }
    }
}
