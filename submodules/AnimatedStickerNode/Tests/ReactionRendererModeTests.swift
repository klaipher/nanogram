import Foundation
import UIKit
import XCTest
import SwiftSignalKit
import AsyncDisplayKit
import Display
import MediaResources
@testable import AnimatedStickerNode

// "GPU for large" is the default renderer mode, and with it every sticker node of 200x200 pixels or
// more takes the Metal renderer. Reaction effects are 240-320 pixels and the large reaction 240, so
// a reaction became the first Metal user of a process: the Metal device, shader library and render
// pipelines were set up on the main thread in the tap that sent it, and its effect was drawn by a
// path upstream never ships (upstream draws reactions on the CPU). Reaction nodes ask for the CPU
// renderer whatever the process-wide mode is.
private final class NeverStickerSource: AnimatedStickerNodeSource {
    let fitzModifier: EmojiFitzModifier? = nil
    let isVideo: Bool = false

    func cachedDataPath(width: Int, height: Int) -> Signal<(String, Bool), NoError> {
        return .never()
    }

    func directDataPath(attemptSynchronously: Bool) -> Signal<String?, NoError> {
        return .never()
    }
}

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

final class ReactionRendererModeTests: XCTestCase {
    private var savedMode: AnimatedStickerRendererMode = .cpu
    private let directory = NSTemporaryDirectory() + "reaction-renderer-mode-" + UUID().uuidString

    override func setUp() {
        super.setUp()
        self.savedMode = AnimatedStickerRendererMode.processWide
        try? FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        AnimatedStickerRendererMode.processWide = self.savedMode
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }


    // Set up before the view loads, so the decision is made without creating a renderer (a Metal one
    // would trap here: the logic-test process has no Metal device).
    private func decision(for node: DefaultAnimatedStickerNodeImpl, size: Int) -> Bool? {
        node.setup(source: NeverStickerSource(), width: size, height: size, playbackMode: .once, mode: .direct(cachePathPrefix: nil))
        return node.usesMetalRenderer
    }

    func testReactionNodeUsesTheCPURendererUnderGpuLarge() {
        AnimatedStickerRendererMode.processWide = .gpuLarge

        // The process-wide mode still applies to other nodes: a 240 px sticker goes to Metal.
        XCTAssertEqual(self.decision(for: DefaultAnimatedStickerNodeImpl(), size: 240), true)

        // A reaction effect (240x240 in the picker flow, 319 for a large reaction) stays on the CPU.
        for size in [80, 240, 319, 480] {
            let node = DefaultAnimatedStickerNodeImpl(rendererMode: .reactions)
            XCTAssertEqual(self.decision(for: node, size: size), false, "a \(size) px reaction node took the Metal renderer")
        }
    }

    func testReactionNodeUsesTheCPURendererUnderGpuAll() {
        AnimatedStickerRendererMode.processWide = .gpuAll
        let node = DefaultAnimatedStickerNodeImpl(rendererMode: .reactions)
        XCTAssertEqual(self.decision(for: node, size: 240), false)
    }

    // A reaction effect played for the first time under the default mode shows frames as images, as
    // upstream does, from a cold cache.
    func testReactionEffectPlaysItsFirstUseOnTheCPUUnderGpuLarge() throws {
        AnimatedStickerRendererMode.processWide = .gpuLarge

        let bundles = [Bundle(for: ReactionRendererModeTests.self), Bundle.main] + Bundle.allBundles
        let path = try XCTUnwrap(bundles.lazy.compactMap({ $0.path(forResource: "Slot_M_Berries", ofType: "tgs") }).first, "fixture missing")

        let size = 240
        let node = DefaultAnimatedStickerNodeImpl(rendererMode: .reactions)
        node.frame = CGRect(x: 0.0, y: 0.0, width: CGFloat(size) / 2.0, height: CGFloat(size) / 2.0)
        var frames = 0
        var started = false
        var completed = false
        node.frameUpdated = { _, _ in
            frames += 1
        }
        node.started = {
            started = true
        }
        node.completed = { _ in
            completed = true
        }
        node.setup(source: FileStickerSource(path: path), width: size, height: size, playbackMode: .once, mode: .direct(cachePathPrefix: self.directory + "/effect"))
        node.updateLayout(size: node.bounds.size)
        guard node.usesMetalRenderer == false else {
            // Loading the view would create a Metal renderer, which traps without a Metal device.
            XCTFail("the reaction effect took the Metal renderer")
            return
        }
        let _ = node.view
        node.overrideVisibility = true
        node.visibility = true

        XCTAssertTrue(spin(timeout: 10.0, { node.currentFrameImage != nil }), "no frame shown")
        XCTAssertTrue(started)
        XCTAssertTrue(spin(timeout: 30.0, { completed }), "never finished")
        XCTAssertGreaterThan(frames, 1)
        node.visibility = false
    }
}
