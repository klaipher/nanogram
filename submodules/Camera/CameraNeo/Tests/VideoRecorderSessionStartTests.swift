import XCTest
import CoreMedia
@testable import CameraNeo

/// Pins how a round video chooses its first frame.
///
/// The recorder holds the first camera frame while it creates the writer and waits for the first
/// audio buffer. Frames that arrive in that time are lost, so starting the file on the held frame
/// left it on screen for the whole delay (a 200 ms frozen first frame, then a jump). The file now
/// starts on the held frame only when the next frame follows it within 1.5 frame intervals.
final class VideoRecorderSessionStartTests: XCTestCase {
    private let frameInterval = CMTime(value: 1, timescale: 30)

    private func time(_ seconds: Double) -> CMTime {
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func choice(held: Double, next: Double) -> VideoRecorder.SessionStartChoice {
        return VideoRecorder.sessionStartChoice(heldTime: self.time(held), nextTime: self.time(next), frameInterval: self.frameInterval)
    }

    func testNextFrameOneIntervalLaterKeepsHeldFrame() {
        XCTAssertEqual(self.choice(held: 10.0, next: 10.0 + 1.0 / 30.0), .startAtHeld)
    }

    func testJitteredNextFrameKeepsHeldFrame() {
        XCTAssertEqual(self.choice(held: 10.0, next: 10.0 + 1.4 / 30.0), .startAtHeld)
        XCTAssertEqual(self.choice(held: 10.0, next: 10.0 + 1.5 / 30.0), .startAtHeld)
    }

    func testOneMissingFrameDropsHeldFrame() {
        XCTAssertEqual(self.choice(held: 10.0, next: 10.0 + 2.0 / 30.0), .startAtNext)
    }

    func testHeldAcrossWriterSetUpDropsHeldFrame() {
        // The measured recording: frame 0, then the next frame 200 ms later.
        XCTAssertEqual(self.choice(held: 10.0, next: 10.2), .startAtNext)
    }

    func testNextFrameNotAfterHeldFrameIsIgnored() {
        XCTAssertEqual(self.choice(held: 10.0, next: 10.0), .ignoreNext)
        XCTAssertEqual(self.choice(held: 10.0, next: 9.9), .ignoreNext)
    }

    func testInvalidTimes() {
        XCTAssertEqual(VideoRecorder.sessionStartChoice(heldTime: self.time(10.0), nextTime: .invalid, frameInterval: self.frameInterval), .ignoreNext)
        XCTAssertEqual(VideoRecorder.sessionStartChoice(heldTime: .invalid, nextTime: self.time(10.0), frameInterval: self.frameInterval), .startAtNext)
    }
}
