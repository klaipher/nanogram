import Foundation
import XCTest
@testable import CrashReporting

final class ActivityIntervalCounterTests: XCTestCase {
    private final class Recorder {
        var events: [String] = []
    }

    private func makeCounter(_ recorder: Recorder) -> ActivityIntervalCounter {
        return ActivityIntervalCounter(onChange: { activity, isActive in
            recorder.events.append("\(activity) \(isActive ? "begin" : "end")")
        })
    }

    func testTwoHoldersAreOneInterval() {
        let recorder = Recorder()
        let counter = self.makeCounter(recorder)
        let first = counter.begin(.stickerPlayback)
        let second = counter.begin(.stickerPlayback)
        XCTAssertEqual(recorder.events, ["stickerPlayback begin"])
        first.end()
        XCTAssertTrue(counter.isActive(.stickerPlayback))
        second.end()
        XCTAssertEqual(recorder.events, ["stickerPlayback begin", "stickerPlayback end"])
        XCTAssertFalse(counter.isActive(.stickerPlayback))
    }

    func testEndingTwiceCountsOnce() {
        let recorder = Recorder()
        let counter = self.makeCounter(recorder)
        let first = counter.begin(.call)
        let second = counter.begin(.call)
        first.end()
        first.end()
        XCTAssertTrue(counter.isActive(.call))
        second.end()
        XCTAssertFalse(counter.isActive(.call))
        XCTAssertEqual(recorder.events.count, 2)
    }

    func testReleasingTheTokenEndsIt() {
        let recorder = Recorder()
        let counter = self.makeCounter(recorder)
        var token: ActivityIntervalCounter.Token? = counter.begin(.roundVideoRecording)
        XCTAssertTrue(counter.isActive(.roundVideoRecording))
        token = nil
        XCTAssertFalse(counter.isActive(.roundVideoRecording))
        XCTAssertEqual(recorder.events, ["roundVideoRecording begin", "roundVideoRecording end"])
        _ = token
    }

    func testActivitiesAreIndependent() {
        let recorder = Recorder()
        let counter = self.makeCounter(recorder)
        let call = counter.begin(.call)
        let video = counter.begin(.videoPlayback)
        call.end()
        XCTAssertTrue(counter.isActive(.videoPlayback))
        XCTAssertFalse(counter.isActive(.call))
        video.end()
    }

    func testUpdateHelperBeginsOnceAndEnds() {
        var token = MetricActivityIntervals.update(nil, .videoPlayback, active: true)
        let again = MetricActivityIntervals.update(token, .videoPlayback, active: true)
        XCTAssertTrue(token === again)
        token = MetricActivityIntervals.update(token, .videoPlayback, active: false)
        XCTAssertNil(token)
    }

    func testVideoPlaybackIsActiveWhilePlayingOrStalledWhilePlaying() {
        XCTAssertTrue(VideoPlaybackActivityPolicy.isActive(isPlaying: true, isBufferingWhilePlaying: false))
        XCTAssertTrue(VideoPlaybackActivityPolicy.isActive(isPlaying: false, isBufferingWhilePlaying: true))
        XCTAssertFalse(VideoPlaybackActivityPolicy.isActive(isPlaying: false, isBufferingWhilePlaying: false))
    }

    func testTwoPlayingVideosAreOneIntervalThatEndsWithTheLastOne() {
        var events: [Bool] = []
        let counter = ActivityIntervalCounter(onChange: { activity, isActive in
            if activity == .videoPlayback {
                events.append(isActive)
            }
        })
        let first = counter.begin(.videoPlayback)
        let second = counter.begin(.videoPlayback)
        first.end()
        XCTAssertEqual(events, [true])
        second.end()
        XCTAssertEqual(events, [true, false])
    }
}
