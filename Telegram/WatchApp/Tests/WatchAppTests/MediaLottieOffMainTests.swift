import XCTest
@testable import tgwatch_Watch_App

/// WATCH-GPU-1: with `renderOffMain` frames are rasterised by `LottieFrameRenderer` and published back to the main
/// actor; a render that is late is dropped in favour of the newest due frame, and a tear-down discards it.
@MainActor
final class MediaLottieOffMainTests: XCTestCase {
    private var stickerPath: String {
        Bundle.main.path(forResource: "sticker_lottie", ofType: "tgs", inDirectory: "SampleStickers") ?? "/missing-sample.tgs"
    }
    private let size = CGSize(width: 240, height: 240)

    /// Waits until no render is running or queued.
    private func settle(_ player: LottieStickerPlayer) async {
        while let task = player.renderTask { await task.value }
    }

    private func loadedPlayer(active: Bool = true) async -> LottieStickerPlayer {
        let player = LottieStickerPlayer(renderOffMain: true)
        player.setActive(active, now: Date())
        player.update(path: stickerPath, isVisible: true, pixelSize: size)
        await player.loadTask?.value
        await settle(player)
        return player
    }

    func testFlagShipsOff() {
        XCTAssertFalse(WatchFeature.offMainStickerRender.defaultValue)
    }

    func testFirstFrameIsPublishedAfterLoad() async {
        let player = await loadedPlayer()
        XCTAssertEqual(player.frame?.width, 240)
        XCTAssertEqual(player.renderCount, 1)
        XCTAssertTrue(player.hasAnimation)
    }

    func testTickPublishesTheDueFrame() async {
        let player = await loadedPlayer()
        guard case .playing(let start) = player.phase else { return XCTFail("phase \(player.phase)") }
        player.tick(now: start.addingTimeInterval(1), pixelSize: size)
        await settle(player)
        XCTAssertEqual(player.renderCount, 2)
    }

    /// Ticks that arrive while a render runs collapse into one: the newest due frame is rendered next.
    func testTicksDuringARenderCollapseToTheNewestFrame() async {
        let player = await loadedPlayer()
        guard case .playing(let start) = player.phase else { return XCTFail() }
        let before = player.renderCount
        for ms in stride(from: 100, through: 900, by: 100) {
            player.tick(now: start.addingTimeInterval(Double(ms) / 1000), pixelSize: size)
        }
        await settle(player)
        // The first tick started a render, the other eight replaced one another: two renders, not nine.
        XCTAssertEqual(player.renderCount - before, 2)
    }

    func testFinishRendersTheLastFrameAndStops() async {
        let player = await loadedPlayer()
        guard case .playing(let start) = player.phase else { return XCTFail() }
        player.tick(now: start.addingTimeInterval(10), pixelSize: size)
        XCTAssertEqual(player.phase, .finished)
        await settle(player)
        XCTAssertNotNil(player.frame, "frozen on the last frame")
        let renders = player.renderCount
        player.tick(now: start.addingTimeInterval(11), pixelSize: size)
        await settle(player)
        XCTAssertEqual(player.renderCount, renders)
    }

    func testScrollingAwayDiscardsAnInFlightRender() async {
        let player = await loadedPlayer()
        guard case .playing(let start) = player.phase else { return XCTFail() }
        player.tick(now: start.addingTimeInterval(1), pixelSize: size)
        player.update(path: stickerPath, isVisible: false)
        XCTAssertNil(player.renderTask)
        XCTAssertNil(player.frame)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(player.frame, "a late result must not bring the frame back")
        XCTAssertFalse(player.hasAnimation)
        XCTAssertEqual(player.phase, .idle)
    }

    func testReplayAfterFinishRendersAgain() async {
        let player = await loadedPlayer()
        guard case .playing(let start) = player.phase else { return XCTFail() }
        player.tick(now: start.addingTimeInterval(10), pixelSize: size)
        await settle(player)
        let now = Date()
        player.replay(now: now)
        player.tick(now: now.addingTimeInterval(0.5), pixelSize: size)
        await settle(player)
        XCTAssertNotNil(player.frame)
        XCTAssertTrue(player.isTicking)
    }

    func testLowPowerModeLowersTheTickRateOnlyWhenTheCapIsOn() {
        XCTAssertEqual(LottieStickerPlayer.minimumFrameInterval(lowPowerMode: false, capEnabled: true), 1.0 / 30.0)
        XCTAssertEqual(LottieStickerPlayer.minimumFrameInterval(lowPowerMode: true, capEnabled: true), 1.0 / 24.0)
        XCTAssertEqual(LottieStickerPlayer.minimumFrameInterval(lowPowerMode: true, capEnabled: false), 1.0 / 30.0)
    }
}
