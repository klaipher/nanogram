import XCTest
import UIKit
import Postbox
import SwiftSignalKit
import TelegramAudio
import UniversalMediaPlayer

// A video playing without sound is suspended while the app is in the background: its clock stops, it asks
// for no frames (it only asks while its clock runs) and its update timer stops, which shows as no status
// updates at all, where a playing video otherwise reports ten a second. It continues from the same position
// in the foreground. A video with sound, and one in Picture in Picture, keep playing.
final class ChunkMediaPlayerV2BackgroundTests: XCTestCase {
    private static let initializeTempBox: Void = {
        TempBox.initializeShared(basePath: NSTemporaryDirectory() + "ChunkMediaPlayerV2BackgroundTests-TempBox", processType: "tests", launchSpecificId: Int64(Date().timeIntervalSince1970 * 1000))
    }()

    private var disposables: [Disposable] = []

    override func tearDown() {
        // The background state is process-wide: leave the next test in the foreground.
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        self.disposables.forEach { $0.dispose() }
        self.disposables = []
        super.tearDown()
    }

    private func spin(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func spin(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func enterBackground() {
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    private func enterForeground() {
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    private final class StatusLog {
        var statuses: [MediaPlayerStatus] = []
        var last: MediaPlayerStatus? {
            return self.statuses.last
        }
    }

    // A 10 s video whose part holds no media: the player decides buffering from part times alone, so its
    // clock runs.
    private func makePlayingPlayer(enableSound: Bool) throws -> (ChunkMediaPlayerV2, MediaPlayerNode, StatusLog) {
        let _ = ChunkMediaPlayerV2BackgroundTests.initializeTempBox

        let playerNode = MediaPlayerNode()
        self.spin(timeout: 2.0, until: { playerNode.videoLayer != nil })
        let _ = try XCTUnwrap(playerNode.videoLayer)

        let part = ChunkMediaPlayerPart(
            startTime: 0.0,
            endTime: 10.0,
            content: ChunkMediaPlayerPart.TempFile(file: TempBox.shared.tempFile(fileName: "part.mp4")),
            codecName: nil,
            offsetTime: 0.0
        )
        let player = ChunkMediaPlayerV2(
            params: ChunkMediaPlayerV2.MediaDataReaderParams(useV2Reader: true),
            audioSessionManager: ManagedAudioSessionImpl(),
            source: .externalParts(.single(ChunkMediaPlayerPartsState(duration: 10.0, content: .parts([part])))),
            video: true,
            enableSound: enableSound,
            playerNode: playerNode
        )
        let log = StatusLog()
        self.disposables.append(player.status.start(next: { status in
            log.statuses.append(status)
        }))
        player.play()

        self.spin(timeout: 2.0, until: { (log.last?.timestamp ?? 0.0) > 0.2 })
        let running = try XCTUnwrap(log.last)
        XCTAssertGreaterThan(running.timestamp, 0.2, "the clock should run in the foreground")
        XCTAssertEqual(running.status, .playing)
        return (player, playerNode, log)
    }

    func testMutedVideoStopsInBackgroundAndContinuesFromTheSamePosition() throws {
        let (player, playerNode, log) = try self.makePlayingPlayer(enableSound: false)

        self.enterBackground()
        let suspended = try XCTUnwrap(log.last)
        XCTAssertEqual(suspended.status, .playing, "a suspended video still reports that it plays")
        XCTAssertEqual(suspended.generationTimestamp, 0.0, "observers must not extrapolate a stopped clock")
        let countAtSuspend = log.statuses.count

        self.spin(for: 0.6)
        XCTAssertEqual(log.statuses.count, countAtSuspend, "a suspended video should not update at all (its timer is stopped)")

        self.enterForeground()
        let resumed = try XCTUnwrap(log.last)
        XCTAssertGreaterThan(log.statuses.count, countAtSuspend)
        XCTAssertEqual(resumed.status, .playing)
        XCTAssertGreaterThan(resumed.generationTimestamp, 0.0)
        XCTAssertEqual(resumed.timestamp, suspended.timestamp, accuracy: 0.02, "the video should continue where it stopped")

        self.spin(for: 0.4)
        XCTAssertGreaterThan(try XCTUnwrap(log.last).timestamp, resumed.timestamp + 0.2, "the clock should run again in the foreground")
        withExtendedLifetime((player, playerNode)) {}
    }

    func testVideoWithSoundKeepsPlayingInBackground() throws {
        let (player, playerNode, log) = try self.makePlayingPlayer(enableSound: true)

        self.enterBackground()
        let atBackground = try XCTUnwrap(log.last)
        XCTAssertGreaterThan(atBackground.generationTimestamp, 0.0)
        let countAtBackground = log.statuses.count

        self.spin(for: 0.6)
        XCTAssertGreaterThan(log.statuses.count, countAtBackground, "a video with sound should keep updating")
        XCTAssertGreaterThan(try XCTUnwrap(log.last).timestamp, atBackground.timestamp + 0.3, "a video with sound should keep playing")
        withExtendedLifetime((player, playerNode)) {}
    }

    func testMutedVideoInPictureInPictureKeepsPlayingInBackground() throws {
        let (player, playerNode, log) = try self.makePlayingPlayer(enableSound: false)

        // What the gallery does when Picture in Picture starts.
        playerNode.setCanPlaybackWithoutHierarchy(true)
        self.enterBackground()
        let atBackground = try XCTUnwrap(log.last)

        self.spin(for: 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(log.last).timestamp, atBackground.timestamp + 0.3, "a video in Picture in Picture should keep playing")
        withExtendedLifetime((player, playerNode)) {}
    }

    func testMutedVideoContinuesWhenPictureInPictureStartsInBackground() throws {
        let (player, playerNode, log) = try self.makePlayingPlayer(enableSound: false)

        self.enterBackground()
        let suspended = try XCTUnwrap(log.last)
        self.spin(for: 0.2)
        XCTAssertEqual(try XCTUnwrap(log.last).timestamp, suspended.timestamp)

        // Picture in Picture can start automatically as the app leaves the foreground.
        playerNode.setCanPlaybackWithoutHierarchy(true)
        self.spin(for: 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(log.last).timestamp, suspended.timestamp + 0.3, "a video in Picture in Picture should play in the background")

        // Picture in Picture ends while the app is still in the background.
        playerNode.setCanPlaybackWithoutHierarchy(false)
        self.spin(for: 0.1)
        let suspendedAgain = try XCTUnwrap(log.last)
        let countAtSuspend = log.statuses.count
        self.spin(for: 0.4)
        XCTAssertEqual(log.statuses.count, countAtSuspend)
        XCTAssertEqual(suspendedAgain.generationTimestamp, 0.0)
        withExtendedLifetime((player, playerNode)) {}
    }
}
