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

    // The player suspends a silent video in the background (no PiP) but keeps reporting it as playing, so the
    // interval must end there, or it spans the process suspension that follows.
    func testVideoPlaybackInTheBackgroundCountsOnlyWithSoundOrPictureInPicture() {
        XCTAssertTrue(VideoPlaybackActivityPolicy.isActive(isPlaying: true, isBufferingWhilePlaying: false, isApplicationInBackground: false, isSoundEnabled: false, isPictureInPictureActive: false))
        XCTAssertFalse(VideoPlaybackActivityPolicy.isActive(isPlaying: true, isBufferingWhilePlaying: false, isApplicationInBackground: true, isSoundEnabled: false, isPictureInPictureActive: false))
        XCTAssertTrue(VideoPlaybackActivityPolicy.isActive(isPlaying: true, isBufferingWhilePlaying: false, isApplicationInBackground: true, isSoundEnabled: true, isPictureInPictureActive: false))
        XCTAssertTrue(VideoPlaybackActivityPolicy.isActive(isPlaying: true, isBufferingWhilePlaying: false, isApplicationInBackground: true, isSoundEnabled: false, isPictureInPictureActive: true))
        XCTAssertFalse(VideoPlaybackActivityPolicy.isActive(isPlaying: false, isBufferingWhilePlaying: true, isApplicationInBackground: true, isSoundEnabled: false, isPictureInPictureActive: false))
        XCTAssertTrue(VideoPlaybackActivityPolicy.isActive(isPlaying: false, isBufferingWhilePlaying: true, isApplicationInBackground: true, isSoundEnabled: true, isPictureInPictureActive: false))
        XCTAssertFalse(VideoPlaybackActivityPolicy.isActive(isPlaying: false, isBufferingWhilePlaying: false, isApplicationInBackground: true, isSoundEnabled: true, isPictureInPictureActive: true))
        XCTAssertFalse(VideoPlaybackActivityPolicy.isActive(isPlaying: false, isBufferingWhilePlaying: false, isApplicationInBackground: false, isSoundEnabled: true, isPictureInPictureActive: false))
    }

    // A silent video that stays "playing" through a trip to the background: the interval ends on entering the
    // background and begins again on returning, once each.
    func testSilentVideoIntervalEndsInTheBackgroundAndBeginsAgainInTheForeground() {
        var events: [Bool] = []
        let counter = ActivityIntervalCounter(onChange: { activity, isActive in
            if activity == .videoPlayback {
                events.append(isActive)
            }
        })
        var token: ActivityIntervalCounter.Token?
        func update(isApplicationInBackground: Bool) {
            let isActive = VideoPlaybackActivityPolicy.isActive(isPlaying: true, isBufferingWhilePlaying: false, isApplicationInBackground: isApplicationInBackground, isSoundEnabled: false, isPictureInPictureActive: false)
            if isActive {
                if token == nil {
                    token = counter.begin(.videoPlayback)
                }
            } else {
                token?.end()
                token = nil
            }
        }
        update(isApplicationInBackground: false)
        XCTAssertEqual(events, [true])
        update(isApplicationInBackground: true)
        update(isApplicationInBackground: true)
        XCTAssertEqual(events, [true, false])
        XCTAssertFalse(counter.isActive(.videoPlayback))
        update(isApplicationInBackground: false)
        update(isApplicationInBackground: false)
        XCTAssertEqual(events, [true, false, true])
        XCTAssertTrue(counter.isActive(.videoPlayback))
        token?.end()
        XCTAssertEqual(events, [true, false, true, false])
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
