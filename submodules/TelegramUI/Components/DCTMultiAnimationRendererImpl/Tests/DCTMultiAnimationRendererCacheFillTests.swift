import Foundation
import UIKit
import XCTest
import SwiftSignalKit
import AnimationCache
import MultiAnimationRenderer
import DCTAnimationCacheImpl
@testable import DCTMultiAnimationRendererImpl

// The first use of an emoji or reaction finds no cache entry: the item is added while the
// entry is still being converted, and its frames only exist once the conversion completes.
// These tests pin that such an item starts animating as soon as its entry is ready.

private func makeSolidItem(frameCount: Int, frameDuration: Double) -> AnimationCacheItem {
    var index = -1
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
        var data = Data(count: 64 * 16)
        data[0] = UInt8(truncatingIfNeeded: index)
        return AnimationCacheItem.AdvanceResult(frame: AnimationCacheItemFrame(format: .rgba(data: data, width: 16, height: 16, bytesPerRow: 64), duration: frameDuration), didLoop: didLoop)
    }, resetImpl: {
        index = -1
    })
}

// Reports "not ready" first, like DCTAnimationCacheImpl on a miss, and the item only when the
// test completes the conversion.
private final class DeferredAnimationCache: AnimationCache {
    private var subscribers: [Subscriber<AnimationCacheItemResult, NoError>] = []
    private let lock = NSLock()

    func complete(item: AnimationCacheItem) {
        self.lock.lock()
        let subscribers = self.subscribers
        self.subscribers.removeAll()
        self.lock.unlock()
        for subscriber in subscribers {
            subscriber.putNext(AnimationCacheItemResult(item: item, isFinal: true))
            subscriber.putCompletion()
        }
    }

    func get(sourceId: String, size: CGSize, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> Signal<AnimationCacheItemResult, NoError> {
        return Signal { subscriber in
            self.lock.lock()
            self.subscribers.append(subscriber)
            self.lock.unlock()
            subscriber.putNext(AnimationCacheItemResult(item: nil, isFinal: false))
            return EmptyDisposable
        }
    }

    func getFirstFrameSynchronously(sourceId: String, size: CGSize) -> AnimationCacheItem? {
        return nil
    }

    func getFirstFrame(queue: Queue, sourceId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (AnimationCacheItemResult) -> Void) -> Disposable {
        completion(AnimationCacheItemResult(item: nil, isFinal: true))
        return EmptyDisposable
    }
}

private final class RecordingTarget: MultiAnimationRenderTarget {
    var transitions = 0

    override func transitionToContents(_ contents: AnyObject, didLoop: Bool) {
        self.transitions += 1
        self.contents = contents
    }
}

private final class FillTestTicker {
    private(set) var interval: Double?
    private var tick: (() -> Void)?

    func makeScheduler() -> DCTAnimationTickScheduler {
        return DCTAnimationTickScheduler(start: { [weak self] interval, tick in
            guard let self else {
                return {}
            }
            self.interval = interval
            self.tick = tick
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

final class DCTMultiAnimationRendererCacheFillTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: Double = 20.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func tick(_ renderer: DCTMultiAnimationRendererImpl, _ ticker: FillTestTicker) {
        ticker.fire()
        self.spin(until: { renderer.pendingFrameLoadsForTesting == 0 })
    }

    func testItemAddedBeforeItsCacheEntryIsReadyStartsAnimating() {
        let ticker = FillTestTicker()
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        let cache = DeferredAnimationCache()
        let target = RecordingTarget()
        target.shouldBeAnimating = true
        let disposable = renderer.add(target: target, cache: cache, itemId: "first-use", unique: true, size: CGSize(width: 16, height: 16), fetch: { _ in EmptyDisposable })

        // Nothing to play yet.
        self.spin(until: { false }, timeout: 0.1)
        XCTAssertNil(renderer.currentTickIntervalForTesting)

        cache.complete(item: makeSolidItem(frameCount: 30, frameDuration: 1.0 / 30.0))
        self.spin(until: { ticker.interval != nil })
        XCTAssertNotNil(ticker.interval, "the renderer did not start ticking when the cache entry became ready")

        for _ in 0 ..< 10 {
            self.tick(renderer, ticker)
        }
        XCTAssertGreaterThanOrEqual(target.transitions, 9)
        disposable.dispose()
    }

    // The same with the real cache: a miss starts the conversion, which finishes after the item
    // was added (as for a reaction used for the first time).
    func testFirstUseOfRealCacheEntryAnimates() {
        let basePath = NSTemporaryDirectory() + "dct-renderer-fill-" + UUID().uuidString
        let tempPath = basePath + "-temp"
        try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tempPath, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: basePath)
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        let cache = DCTAnimationCacheImpl(basePath: basePath, allocateTempFile: {
            return tempPath + "/" + UUID().uuidString
        }, updateStorageStats: { _, _ in
        })

        let size = 64
        let frameCount = 20
        let fetch: (AnimationCacheFetchOptions) -> Disposable = { options in
            let writer = options.writer
            writer.queue.after(0.3, {
                for index in 0 ..< frameCount {
                    writer.add(with: { surface in
                        for y in 0 ..< surface.height {
                            let row = surface.argb.advanced(by: y * surface.bytesPerRow)
                            for x in 0 ..< surface.width {
                                let inside = abs(x - index * 3) < 8
                                row[x * 4 + 0] = inside ? 255 : 0
                                row[x * 4 + 1] = UInt8(truncatingIfNeeded: index * 10)
                                row[x * 4 + 2] = 0
                                row[x * 4 + 3] = 255
                            }
                        }
                        return 1.0 / 30.0
                    }, proposedWidth: size, proposedHeight: size, insertKeyframe: index == 0)
                }
                writer.finish()
            })
            return EmptyDisposable
        }

        for pass in 0 ..< 2 {
            // As InlineStickerItemLayer without a synchronous load: the first frame first, then the item.
            var firstFrameResult: (Bool, Bool)?
            let firstFrameTarget = RecordingTarget()
            let firstFrameDisposable = DCTMultiAnimationRendererImpl(tickScheduler: FillTestTicker().makeScheduler()).loadFirstFrame(target: firstFrameTarget, cache: cache, itemId: "reaction", size: CGSize(width: size, height: size), fetch: fetch, completion: { result, isFinal in
                if isFinal {
                    firstFrameResult = (result, isFinal)
                }
            })
            self.spin(until: { firstFrameResult != nil })
            XCTAssertEqual(firstFrameResult?.0, true, "pass \(pass): no first frame")
            XCTAssertNotNil(firstFrameTarget.contents, "pass \(pass)")
            firstFrameDisposable.dispose()

            let ticker = FillTestTicker()
            let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
            let target = RecordingTarget()
            target.shouldBeAnimating = true
            let disposable = renderer.add(target: target, cache: cache, itemId: "reaction", unique: true, size: CGSize(width: size, height: size), fetch: fetch)
            self.spin(until: { ticker.interval != nil })
            XCTAssertNotNil(ticker.interval, "pass \(pass): the renderer never started ticking")
            for _ in 0 ..< 10 {
                self.tick(renderer, ticker)
            }
            XCTAssertGreaterThanOrEqual(target.transitions, 9, "pass \(pass)")
            disposable.dispose()
        }
    }
}
