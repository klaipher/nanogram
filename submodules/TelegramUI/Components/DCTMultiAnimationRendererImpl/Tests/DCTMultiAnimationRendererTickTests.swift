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

// Ticks only when the test fires it, so frame counts do not depend on wall-clock time or CPU load.
private final class ManualTicker {
    private(set) var interval: Double?
    private var tick: (() -> Void)?
    private(set) var startCount = 0

    func makeScheduler() -> DCTAnimationTickScheduler {
        return DCTAnimationTickScheduler(start: { [weak self] interval, tick in
            guard let self else {
                return {}
            }
            self.interval = interval
            self.tick = tick
            self.startCount += 1
            return { [weak self] in
                self?.interval = nil
                self?.tick = nil
            }
        })
    }

    func fire() {
        self.tick?()
    }
}

final class DCTMultiAnimationRendererTickTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: Double = 10.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    // Fires one tick and waits until the frames it requested have been delivered.
    private func tick(_ renderer: DCTMultiAnimationRendererImpl, _ ticker: ManualTicker) {
        ticker.fire()
        self.spin(until: { renderer.pendingFrameLoadsForTesting == 0 })
        XCTAssertEqual(renderer.pendingFrameLoadsForTesting, 0)
    }

    private func play(frameDurations: [Double], ticker: ManualTicker) -> (renderer: DCTMultiAnimationRendererImpl, targets: [CountingTarget], disposables: [Disposable]) {
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        var targets: [CountingTarget] = []
        var disposables: [Disposable] = []
        for (index, duration) in frameDurations.enumerated() {
            let target = CountingTarget()
            target.shouldBeAnimating = true
            let cache = FakeAnimationCache(frameDuration: duration)
            disposables.append(renderer.add(target: target, cache: cache, itemId: "item\(index)", unique: false, size: CGSize(width: 16, height: 16), fetch: { _ in EmptyDisposable }))
            targets.append(target)
        }
        // Items arrive through the main queue; then the first tick loads every first frame.
        self.spin(until: { ticker.interval != nil })
        self.tick(renderer, ticker)
        return (renderer, targets, disposables)
    }

    private var highRateAvailable: Bool {
        return DCTAnimationTickPolicy.frameSkip(isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState, processorCount: ProcessInfo.processInfo.processorCount) == 1
    }

    func testThirtyFpsContentTicksAtThirtyHertz() {
        let ticker = ManualTicker()
        let (renderer, targets, disposables) = self.play(frameDurations: [1.0 / 30.0, 2.0 / 30.0, 1.0], ticker: ticker)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(ticker.interval ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)

        // One second of ticks: 30 frames of the 30 fps item, 15 of the 15 fps item.
        let before = targets.map(\.transitions)
        for _ in 0 ..< 30 {
            self.tick(renderer, ticker)
        }
        XCTAssertEqual(targets[0].transitions - before[0], 30)
        XCTAssertEqual(targets[1].transitions - before[1], 15)
        XCTAssertLessThanOrEqual(targets[2].transitions - before[2], 1)
        disposables.forEach { $0.dispose() }
    }

    func testOtherFrameRatesKeepSixtyHertz() throws {
        try XCTSkipUnless(self.highRateAvailable)
        let ticker = ManualTicker()
        let (renderer, targets, disposables) = self.play(frameDurations: [1.0 / 30.0, 1.0 / 24.0], ticker: ticker)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 1.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(ticker.interval ?? 0.0, 1.0 / 60.0, accuracy: 0.0001)

        // One second at 60 Hz: 30 frames of the 30 fps item. A 1/24 s frame is shown for
        // 3 ticks (the overshoot is not carried into the next frame), so 20 frames today.
        let before = targets.map(\.transitions)
        for _ in 0 ..< 60 {
            self.tick(renderer, ticker)
        }
        XCTAssertEqual(targets[0].transitions - before[0], 30)
        XCTAssertTrue((20 ... 24).contains(targets[1].transitions - before[1]), "\(targets[1].transitions - before[1])")

        // When the 24 fps item goes away, the tick drops back to 30 Hz.
        targets[1].shouldBeAnimating = false
        self.spin(until: { renderer.currentTickIntervalForTesting.map { abs($0 - 2.0 / 60.0) < 0.0001 } ?? false })
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(ticker.interval ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        disposables.forEach { $0.dispose() }
    }

    func testStoppedRendererHasNoTimer() {
        let ticker = ManualTicker()
        let (renderer, targets, disposables) = self.play(frameDurations: [1.0 / 30.0], ticker: ticker)
        XCTAssertNotNil(renderer.currentTickIntervalForTesting)
        targets[0].shouldBeAnimating = false
        self.spin(until: { renderer.currentTickIntervalForTesting == nil })
        XCTAssertNil(renderer.currentTickIntervalForTesting)
        XCTAssertNil(ticker.interval)
        disposables.forEach { $0.dispose() }
    }

    // Leaving a screen with animated emoji disposes its items; the timer must stop with them.
    func testTimerStopsWhenLastPlayingItemIsRemoved() {
        let ticker = ManualTicker()
        let (renderer, targets, disposables) = self.play(frameDurations: [1.0 / 30.0, 1.0 / 24.0], ticker: ticker)
        XCTAssertNotNil(renderer.currentTickIntervalForTesting)
        disposables[1].dispose()
        self.spin(until: { renderer.currentTickIntervalForTesting.map { abs($0 - 2.0 / 60.0) < 0.0001 } ?? false })
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        disposables[0].dispose()
        self.spin(until: { renderer.currentTickIntervalForTesting == nil })
        XCTAssertNil(renderer.currentTickIntervalForTesting)
        XCTAssertNil(ticker.interval)
        _ = targets
    }

    func testTimerStopsWhenLayerIsReleased() {
        let ticker = ManualTicker()
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        var target: CountingTarget? = CountingTarget()
        target?.shouldBeAnimating = true
        let disposable = renderer.add(target: target!, cache: FakeAnimationCache(frameDuration: 1.0 / 30.0), itemId: "item", unique: false, size: CGSize(width: 16, height: 16), fetch: { _ in EmptyDisposable })
        self.spin(until: { ticker.interval != nil })
        self.tick(renderer, ticker)
        XCTAssertNotNil(renderer.currentTickIntervalForTesting)
        target = nil
        self.spin(until: { renderer.currentTickIntervalForTesting == nil })
        XCTAssertNil(renderer.currentTickIntervalForTesting)
        XCTAssertNil(ticker.interval)
        disposable.dispose()
    }

    // The run loop timer is the fallback scheduler (the default one follows the display).
    func testRunLoopTimerSchedulerTicks() {
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: .runLoopTimer)
        let target = CountingTarget()
        target.shouldBeAnimating = true
        let disposable = renderer.add(target: target, cache: FakeAnimationCache(frameDuration: 1.0 / 30.0), itemId: "item", unique: false, size: CGSize(width: 16, height: 16), fetch: { _ in EmptyDisposable })
        self.spin(until: { target.transitions >= 3 })
        XCTAssertGreaterThanOrEqual(target.transitions, 3)
        disposable.dispose()
        self.spin(until: { renderer.currentTickIntervalForTesting == nil })
        XCTAssertNil(renderer.currentTickIntervalForTesting)
    }

    // Low Power Mode and the thermal state are watched while the renderer lives: a change moves the tick
    // between 60 and 30 Hz without a relaunch.
    func testPowerStateChangesMoveTheTickRate() throws {
        try XCTSkipUnless(self.highRateAvailable, "needs a device with the full rate available")
        let ticker = ManualTicker()
        let (renderer, _, disposables) = self.play(frameDurations: [1.0 / 24.0], ticker: ticker)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 1.0 / 60.0, accuracy: 0.0001)
        renderer.updatePowerState(isLowPowerMode: true, thermalState: .nominal)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(ticker.interval ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        renderer.updatePowerState(isLowPowerMode: false, thermalState: .serious)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 2.0 / 60.0, accuracy: 0.0001)
        renderer.updatePowerState(isLowPowerMode: false, thermalState: .fair)
        XCTAssertEqual(renderer.currentTickIntervalForTesting ?? 0.0, 1.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(ticker.interval ?? 0.0, 1.0 / 60.0, accuracy: 0.0001)
        for disposable in disposables {
            disposable.dispose()
        }
    }

    // An unchanged power state must not restart the tick.
    func testUnchangedPowerStateKeepsTheTick() throws {
        try XCTSkipUnless(self.highRateAvailable, "needs a device with the full rate available")
        let ticker = ManualTicker()
        let (renderer, _, disposables) = self.play(frameDurations: [1.0 / 24.0], ticker: ticker)
        let starts = ticker.startCount
        renderer.updatePowerState(isLowPowerMode: false, thermalState: .nominal)
        XCTAssertEqual(ticker.startCount, starts)
        for disposable in disposables {
            disposable.dispose()
        }
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

    // Durations come from cache files: odd values must classify without trapping.
    func testDurationClassificationOfOddValues() {
        XCTAssertTrue(animationFrameDurationNeedsHighTickRate(0.0))
        XCTAssertTrue(animationFrameDurationNeedsHighTickRate(-0.0))
        XCTAssertTrue(animationFrameDurationNeedsHighTickRate(-1.0 / 30.0))
        XCTAssertTrue(animationFrameDurationNeedsHighTickRate(Double.leastNonzeroMagnitude))
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(Double.nan))
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(Double.infinity))
        XCTAssertTrue(animationFrameDurationNeedsHighTickRate(-Double.infinity))
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(Double.greatestFiniteMagnitude))
        XCTAssertFalse(animationFrameDurationNeedsHighTickRate(1e12))
    }
}
