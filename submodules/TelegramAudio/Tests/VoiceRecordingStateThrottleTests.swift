import XCTest
@testable import TelegramAudio

// ManagedAudioRecorder compared `last < now + 0.1`, which is always true, so the recording state was
// published for every 20 ms encoder packet (50 Hz). It is now published at most every 1/30 s.
final class VoiceRecordingStateThrottleTests: XCTestCase {
    func testPacketsEvery20msPublishAtMost30TimesASecond() {
        var throttle = VoiceRecordingStateThrottle()
        var published: [Double] = []
        let start = 1000.0
        for i in 0 ..< 500 {
            let timestamp = start + Double(i) * 0.02
            if throttle.shouldPublish(at: timestamp) {
                published.append(timestamp)
            }
        }
        // The first packet always publishes, so the timer starts right away.
        XCTAssertEqual(published.first, start)
        let seconds = 500.0 * 0.02
        XCTAssertLessThanOrEqual(Double(published.count) / seconds, 30.0)
        XCTAssertGreaterThanOrEqual(Double(published.count) / seconds, 20.0)
        for i in 1 ..< published.count {
            XCTAssertGreaterThanOrEqual(published[i] - published[i - 1], VoiceRecordingStateThrottle.minimumInterval - 1e-9)
            // Never more than two packets (40 ms) without an update.
            XCTAssertLessThanOrEqual(published[i] - published[i - 1], 0.04 + 1e-9)
        }
    }

    func testIrregularPacketsKeepTheMinimumInterval() {
        var throttle = VoiceRecordingStateThrottle()
        XCTAssertTrue(throttle.shouldPublish(at: 5.0))
        XCTAssertFalse(throttle.shouldPublish(at: 5.01))
        XCTAssertFalse(throttle.shouldPublish(at: 5.03))
        XCTAssertTrue(throttle.shouldPublish(at: 5.034))
        // A late packet after a stall publishes at once.
        XCTAssertTrue(throttle.shouldPublish(at: 9.0))
    }
}
