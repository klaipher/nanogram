import Foundation
import UIKit
import XCTest
import SwiftSignalKit
import AnimationCache
import MultiAnimationRenderer
@testable import DCTMultiAnimationRendererImpl

// An animation of solid frames with a fixed duration, served from memory.
private final class FakeAnimationCache: AnimationCache {
    let frameDuration: Double
    let frameCount: Int

    init(frameDuration: Double, frameCount: Int = 30) {
        self.frameDuration = frameDuration
        self.frameCount = frameCount
    }

    func makeItem() -> AnimationCacheItem {
        var index = -1
        let frameCount = self.frameCount
        let frameDuration = self.frameDuration
        return AnimationCacheItem(numFrames: frameCount, advanceImpl: { advance, _ in
            var didLoop = false
            let steps: Int
            switch advance {
            case let .frames(count):
                steps = count
            case let .duration(duration):
                steps = max(1, Int((duration / frameDuration).rounded()))
            }
            for _ in 0 ..< steps {
                index += 1
                if index >= frameCount {
                    index = 0
                    didLoop = true
                }
            }
            let width = 16, height = 16, bytesPerRow = 64
            var data = Data(count: bytesPerRow * height)
            data[0] = UInt8(index)
            return AnimationCacheItem.AdvanceResult(frame: AnimationCacheItemFrame(format: .rgba(data: data, width: width, height: height, bytesPerRow: bytesPerRow), duration: frameDuration), didLoop: didLoop)
        }, resetImpl: {
            index = -1
        })
    }

    func get(sourceId: String, size: CGSize, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> Signal<AnimationCacheItemResult, NoError> {
        return .single(AnimationCacheItemResult(item: self.makeItem(), isFinal: true))
    }

    func getFirstFrameSynchronously(sourceId: String, size: CGSize) -> AnimationCacheItem? {
        return nil
    }

    func getFirstFrame(queue: Queue, sourceId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (AnimationCacheItemResult) -> Void) -> Disposable {
        completion(AnimationCacheItemResult(item: nil, isFinal: true))
        return EmptyDisposable
    }
}

private final class CountingTarget: MultiAnimationRenderTarget {
    var transitions = 0

    override func transitionToContents(_ contents: AnyObject, didLoop: Bool) {
        self.transitions += 1
    }
}

final class DCTMultiAnimationRendererTickTests: XCTestCase {
    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func play(frameDurations: [Double], seconds: Double) -> (renderer: DCTMultiAnimationRendererImpl, targets: [CountingTarget], disposables: [Disposable]) {
        let renderer = DCTMultiAnimationRendererImpl()
        var targets: [CountingTarget] = []
        var disposables: [Disposable] = []
        for (index, duration) in frameDurations.enumerated() {
            let target = CountingTarget()
            target.shouldBeAnimating = true
            let cache = FakeAnimationCache(frameDuration: duration)
            disposables.append(renderer.add(target: target, cache: cache, itemId: "item\(index)", unique: false, size: CGSize(width: 16, height: 16), fetch: { _ in EmptyDisposable }))
            targets.append(target)
        }
        self.spin(seconds)
        return (renderer, targets, disposables)
    }

    private var highRateAvailable: Bool {
        return !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.processorCount > 2
    }

    func testThirtyFpsContentTicksAtThirtyHertz() {
        let (renderer, targets, disposables) = self.play(frameDurations: [1.0 / 30.0, 2.0 / 30.0, 1.0], seconds: 0.3)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)

        // Frames still change at the content's own rate.
        let before = targets[0].transitions
        self.spin(1.0)
        let shown = targets[0].transitions - before
        XCTAssertGreaterThan(shown, 24)
        XCTAssertLessThan(shown, 34)
        disposables.forEach { $0.dispose() }
    }

    func testOtherFrameRatesKeepSixtyHertz() throws {
        try XCTSkipUnless(self.highRateAvailable)
        let (renderer, targets, disposables) = self.play(frameDurations: [1.0 / 30.0, 1.0 / 24.0], seconds: 0.3)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 1.0 / 60.0, accuracy: 0.0001)

        let before = targets[1].transitions
        self.spin(1.0)
        let shown = targets[1].transitions - before
        XCTAssertGreaterThan(shown, 19)
        XCTAssertLessThan(shown, 27)

        // When the 24 fps item goes away, the tick drops back to 30 Hz.
        targets[1].shouldBeAnimating = false
        self.spin(0.1)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        disposables.forEach { $0.dispose() }
    }

    func testStoppedRendererHasNoTimer() {
        let (renderer, targets, disposables) = self.play(frameDurations: [1.0 / 30.0], seconds: 0.2)
        XCTAssertNotNil(renderer.currentTickIntervalForTesting)
        targets[0].shouldBeAnimating = false
        self.spin(0.1)
        XCTAssertNil(renderer.currentTickIntervalForTesting)
        disposables.forEach { $0.dispose() }
    }

    // Leaving a screen with animated emoji disposes its items; the timer must stop with them.
    func testTimerStopsWhenLastPlayingItemIsRemoved() {
        let (renderer, targets, disposables) = self.play(frameDurations: [1.0 / 30.0, 1.0 / 24.0], seconds: 0.2)
        XCTAssertNotNil(renderer.currentTickIntervalForTesting)
        disposables[1].dispose()
        self.spin(0.1)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        disposables[0].dispose()
        self.spin(0.1)
        XCTAssertNil(renderer.currentTickIntervalForTesting)
        _ = targets
    }

    func testTimerStopsWhenLayerIsReleased() {
        let renderer = DCTMultiAnimationRendererImpl()
        var target: CountingTarget? = CountingTarget()
        target?.shouldBeAnimating = true
        let disposable = renderer.add(target: target!, cache: FakeAnimationCache(frameDuration: 1.0 / 30.0), itemId: "item", unique: false, size: CGSize(width: 16, height: 16), fetch: { _ in EmptyDisposable })
        self.spin(0.2)
        XCTAssertNotNil(renderer.currentTickIntervalForTesting)
        target = nil
        self.spin(0.1)
        XCTAssertNil(renderer.currentTickIntervalForTesting)
        disposable.dispose()
    }

    func testDurationClassification() {
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(1.0 / 30.0))
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(Double(Float32(1.0 / 30.0))))
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(2.0 / 60.0))
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(2.0 / 30.0))
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(1.0))
        XCTAssertTrue(animationFrameDurationNeedsHighTickRate(1.0 / 24.0))
        XCTAssertTrue(animationFrameDurationNeedsHighTickRate(1.0 / 25.0))
        XCTAssertTrue(animationFrameDurationNeedsHighTickRate(1.0 / 60.0))
    }
}
