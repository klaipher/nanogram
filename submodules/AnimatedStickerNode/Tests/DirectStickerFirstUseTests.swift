import Foundation
import UIKit
import XCTest
import SwiftSignalKit
import AsyncDisplayKit
import Display
import LottieSettings
import MediaResources
@testable import AnimatedStickerNode

// A reaction's centre and effect animations play once through DefaultAnimatedStickerNodeImpl in
// `.direct` mode with a short-lived frame cache. The first use finds no cache file: frames are
// rendered by lottie and stored meanwhile. Later uses read the stored frames.
// Both must play every frame.

private final class FileStickerSource: AnimatedStickerNodeSource {
    let path: String
    let fitzModifier: EmojiFitzModifier? = nil
    let isVideo: Bool = false

    init(path: String) {
        self.path = path
    }

    func cachedDataPath(width: Int, height: Int) -> Signal<(String, Bool), NoError> {
        return .never()
    }

    func directDataPath(attemptSynchronously: Bool) -> Signal<String?, NoError> {
        return .single(self.path)
    }
}

private func spin(timeout: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return condition()
}

final class DirectStickerFirstUseTests: XCTestCase {
    private let directory = NSTemporaryDirectory() + "direct-sticker-first-use-" + UUID().uuidString

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    private func stickerPath() throws -> String {
        let bundles = [Bundle(for: DirectStickerFirstUseTests.self), Bundle.main] + Bundle.allBundles
        return try XCTUnwrap(bundles.lazy.compactMap({ $0.path(forResource: "Slot_M_Berries", ofType: "tgs") }).first, "fixture missing")
    }

    private struct Playback {
        var frames: [Int] = []
        var started = false
        var completed = false
        var hasImage = false
    }

    private func playOnce(path: String, cachePathPrefix: String, size: Int, lottieSettings: LottieRenderingSettings) -> Playback {
        let node = DefaultAnimatedStickerNodeImpl(lottieSettings: lottieSettings)
        node.frame = CGRect(x: 0.0, y: 0.0, width: CGFloat(size) / 2.0, height: CGFloat(size) / 2.0)
        var playback = Playback()
        node.frameUpdated = { index, _ in
            playback.frames.append(index)
        }
        node.started = {
            playback.started = true
        }
        node.completed = { _ in
            playback.completed = true
        }
        node.setup(source: FileStickerSource(path: path), width: size, height: size, playbackMode: .once, mode: .direct(cachePathPrefix: cachePathPrefix))
        node.updateLayout(size: node.bounds.size)
        let _ = node.view
        node.overrideVisibility = true
        node.visibility = true
        let _ = spin(timeout: 30.0, { playback.completed })
        playback.hasImage = node.currentFrameImage != nil
        node.visibility = false
        return playback
    }

    private func checkFirstAndSecondUse(lottieSettings: LottieRenderingSettings) throws {
        let path = try self.stickerPath()
        let prefix = self.directory + "/reaction-\(lottieSettings.backend)"
        let size = 240

        let first = self.playOnce(path: path, cachePathPrefix: prefix, size: size, lottieSettings: lottieSettings)
        // Frames are stored asynchronously; let them land before the second use.
        let _ = spin(timeout: 2.0, { false })
        let second = self.playOnce(path: path, cachePathPrefix: prefix, size: size, lottieSettings: lottieSettings)

        FileHandle.standardError.write(Data("FIRSTUSE \(lottieSettings.backend) first: frames=\(first.frames.count) started=\(first.started) completed=\(first.completed) image=\(first.hasImage); second: frames=\(second.frames.count) started=\(second.started) completed=\(second.completed) image=\(second.hasImage)\n".utf8))

        XCTAssertTrue(first.started, "first use never showed a frame")
        XCTAssertTrue(first.completed, "first use never finished")
        XCTAssertTrue(first.hasImage)
        XCTAssertTrue(second.started)
        XCTAssertTrue(second.completed)
        XCTAssertGreaterThan(first.frames.count, 1)
        XCTAssertEqual(first.frames.count, second.frames.count)
    }

    func testFirstAndSecondUsePlayEveryFrameWithTLottie() throws {
        try self.checkFirstAndSecondUse(lottieSettings: LottieRenderingSettings(backend: .tlottie))
    }

    func testFirstAndSecondUsePlayEveryFrameWithRLottie() throws {
        try self.checkFirstAndSecondUse(lottieSettings: LottieRenderingSettings(backend: .rlottie))
    }
}
