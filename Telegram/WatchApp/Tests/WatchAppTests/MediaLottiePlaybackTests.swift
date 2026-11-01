import XCTest
@testable import tgwatch_Watch_App

/// Animated (TGS) chat stickers. The message list is a plain VStack, so `onAppear` fires
/// for every row of the loaded window at once: every downloaded animated sticker in the
/// chat was parsed and played at 30 fps, on screen or not, and a TimelineView kept
/// ticking at 30 Hz for each of them forever, also after the animation ended and while
/// the wrist was down. The player loads only while the bubble is visible and ticks only
/// while it has a frame to advance.
@MainActor
final class MediaLottiePlaybackTests: XCTestCase {
    /// The preview sample (Debug builds bundle `Assets/SampleStickers`).
    private var stickerPath: String {
        Bundle.main.path(forResource: "sticker_lottie", ofType: "tgs", inDirectory: "SampleStickers") ?? "/missing-sample.tgs"
    }

    func testSampleStickerIsBundled() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: stickerPath))
    }

    private func loadedPlayer(active: Bool = true) async -> LottieStickerPlayer {
        let player = LottieStickerPlayer()
        player.setActive(active, now: Date())
        player.update(path: stickerPath, isVisible: true, pixelSize: CGSize(width: 240, height: 240))
        await player.loadTask?.value
        return player
    }

    func testFrameIndex() {
        // The sample: 156 frames at 60 fps (2.6 s).
        XCTAssertEqual(LottieStickerPlayer.frameIndex(elapsed: 0, frameCount: 156, frameRate: 60), 0)
        XCTAssertEqual(LottieStickerPlayer.frameIndex(elapsed: 1, frameCount: 156, frameRate: 60), 60)
        XCTAssertEqual(LottieStickerPlayer.frameIndex(elapsed: 2.59, frameCount: 156, frameRate: 60), 155)
        XCTAssertNil(LottieStickerPlayer.frameIndex(elapsed: 2.6, frameCount: 156, frameRate: 60))
        XCTAssertEqual(LottieStickerPlayer.frameIndex(elapsed: -1, frameCount: 156, frameRate: 60), 0)
    }

    func testOffScreenStickerIsNotLoaded() async {
        let player = LottieStickerPlayer()
        player.update(path: stickerPath, isVisible: false)
        await player.loadTask?.value
        XCTAssertEqual(player.phase, .idle)
        XCTAssertNil(player.loadTask)
        XCTAssertFalse(player.isTicking)
        XCTAssertFalse(player.hasAnimation)
    }

    func testVisibleStickerLoadsAndPlays() async {
        let player = await loadedPlayer()
        guard case .playing = player.phase else { return XCTFail("phase \(player.phase)") }
        XCTAssertTrue(player.isTicking)
        XCTAssertTrue(player.hasAnimation)
        player.tick(now: Date(), pixelSize: CGSize(width: 240, height: 240))
        XCTAssertEqual(player.frame?.width, 240)
    }

    func testNotDownloadedYetWaitsForThePath() async {
        let player = LottieStickerPlayer()
        player.update(path: nil, isVisible: true)
        XCTAssertNil(player.loadTask)
        XCTAssertEqual(player.phase, .idle)
        player.update(path: stickerPath, isVisible: true)
        await player.loadTask?.value
        guard case .playing = player.phase else { return XCTFail("phase \(player.phase)") }
    }

    func testScrollingAwayReleasesTheAnimation() async {
        let player = await loadedPlayer()
        player.tick(now: Date(), pixelSize: CGSize(width: 240, height: 240))
        player.update(path: stickerPath, isVisible: false)
        XCTAssertEqual(player.phase, .idle)
        XCTAssertNil(player.frame)
        XCTAssertFalse(player.hasAnimation)
        XCTAssertFalse(player.isTicking)
    }

    func testScrollingAwayDuringLoadDropsTheResult() async {
        let player = LottieStickerPlayer()
        player.update(path: stickerPath, isVisible: true)
        let task = player.loadTask
        player.update(path: stickerPath, isVisible: false)
        await task?.value
        XCTAssertEqual(player.phase, .idle)
        XCTAssertFalse(player.hasAnimation)
    }

    func testStopsTickingOnTheLastFrame() async {
        let player = await loadedPlayer()
        guard case .playing(let start) = player.phase else { return XCTFail() }
        player.tick(now: start.addingTimeInterval(10), pixelSize: CGSize(width: 240, height: 240))
        XCTAssertEqual(player.phase, .finished)
        XCTAssertFalse(player.isTicking)
        XCTAssertNotNil(player.frame, "frozen on the last frame")
        let renders = player.renderCount
        player.tick(now: start.addingTimeInterval(11), pixelSize: CGSize(width: 240, height: 240))
        XCTAssertEqual(player.renderCount, renders, "no work after the end")
    }

    func testTapReplays() async {
        let player = await loadedPlayer()
        guard case .playing(let start) = player.phase else { return XCTFail() }
        player.tick(now: start.addingTimeInterval(10), pixelSize: CGSize(width: 240, height: 240))
        let now = Date()
        player.replay(now: now)
        XCTAssertEqual(player.phase, .playing(start: now))
        XCTAssertTrue(player.isTicking)
    }

    func testTapWhilePlayingDoesNothing() async {
        let player = await loadedPlayer()
        let phase = player.phase
        player.replay(now: Date().addingTimeInterval(1))
        XCTAssertEqual(player.phase, phase)
    }

    func testPausesWhileInactiveAndResumesInPlace() async {
        let player = await loadedPlayer()
        guard case .playing(let start) = player.phase else { return XCTFail() }
        player.setActive(false, now: start.addingTimeInterval(1))
        guard case .paused(let elapsed) = player.phase else { return XCTFail("phase \(player.phase)") }
        XCTAssertEqual(elapsed, 1, accuracy: 0.001)
        XCTAssertFalse(player.isTicking)
        let renders = player.renderCount
        player.tick(now: start.addingTimeInterval(2), pixelSize: CGSize(width: 240, height: 240))
        XCTAssertEqual(player.renderCount, renders)

        // Wrist up 30 s later: continues from 1 s, not from the end.
        let resumed = start.addingTimeInterval(31)
        player.setActive(true, now: resumed)
        guard case .playing(let newStart) = player.phase else { return XCTFail("phase \(player.phase)") }
        XCTAssertEqual(newStart.timeIntervalSince(resumed), -1, accuracy: 0.001)
        XCTAssertTrue(player.isTicking)
    }

    func testLoadedWhileInactiveStartsPaused() async {
        let player = await loadedPlayer(active: false)
        XCTAssertEqual(player.phase, .paused(elapsed: 0))
        XCTAssertFalse(player.isTicking)
        XCTAssertNotNil(player.frame, "shows the first frame")
    }

    func testUnreadableFileFails() async {
        let player = LottieStickerPlayer()
        player.update(path: "/nonexistent.tgs", isVisible: true)
        await player.loadTask?.value
        XCTAssertEqual(player.phase, .failed)
        XCTAssertFalse(player.isTicking)
        // Not retried on every re-evaluation.
        player.update(path: "/nonexistent.tgs", isVisible: true)
        XCTAssertNil(player.loadTask)
    }
}
