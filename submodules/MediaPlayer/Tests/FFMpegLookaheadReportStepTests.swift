import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

/// The lookahead reader reports its readable range to the player (a main-queue hop and a full player update per
/// report). The advance counters used to grow for the whole read pass, so once a pass had read 0.1 s every later
/// packet sent a report. With the wake gate the reader tops the buffer up in 2 s passes, so that was about 140 reports
/// per pass; the step keeps it at one report per 0.1 s of media.
final class FFMpegLookaheadReportStepTests: XCTestCase {
    private func reportsInPass(seconds: Double, audioPacket: Double?, videoPacket: Double?) -> Int {
        var step = FFMpegLookaheadReportStep()
        var audioTime = 0.0
        var videoTime = 0.0
        var reports = 0
        while true {
            let nextAudio = audioPacket.map { audioTime + $0 }
            let nextVideo = videoPacket.map { videoTime + $0 }
            let next = min(nextAudio ?? .infinity, nextVideo ?? .infinity)
            if next > seconds {
                break
            }
            if let nextAudio, nextAudio == next, let audioPacket {
                step.addAudio(audioPacket)
                audioTime = nextAudio
            } else if let videoPacket, let nextVideo {
                step.addVideo(videoPacket)
                videoTime = nextVideo
            }
            if step.takeIfDue() {
                reports += 1
            }
        }
        return reports
    }

    func testATwoSecondRefillReportsAboutEveryTenthOfASecond() {
        let reports = self.reportsInPass(seconds: 2.0, audioPacket: 1024.0 / 48000.0, videoPacket: 1.0 / 30.0)
        XCTAssertGreaterThanOrEqual(reports, 15)
        XCTAssertLessThanOrEqual(reports, 20)
    }

    func testNothingIsDueBeforeBothStreamsAdvancedATenthOfASecond() {
        var step = FFMpegLookaheadReportStep()
        step.addVideo(0.5)
        XCTAssertFalse(step.takeIfDue())
        step.addAudio(0.09)
        XCTAssertFalse(step.takeIfDue())
        step.addAudio(0.02)
        XCTAssertTrue(step.takeIfDue())
    }

    func testTheCountersStartOverAfterAReport() {
        var step = FFMpegLookaheadReportStep()
        step.addAudio(0.2)
        step.addVideo(0.2)
        XCTAssertTrue(step.takeIfDue())
        step.addAudio(0.02)
        step.addVideo(0.02)
        XCTAssertFalse(step.takeIfDue())
    }

    func testAFileWithOneStreamOnlyReportsAtTheEndOfThePassAsBefore() {
        XCTAssertEqual(self.reportsInPass(seconds: 2.0, audioPacket: nil, videoPacket: 1.0 / 30.0), 0)
    }
}
