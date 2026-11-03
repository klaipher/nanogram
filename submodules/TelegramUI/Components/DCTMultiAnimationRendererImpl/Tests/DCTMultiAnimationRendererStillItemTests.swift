import Foundation
import UIKit
import XCTest
import SwiftSignalKit
import AnimationCache
import MultiAnimationRenderer
import DCTAnimationCacheImpl
@testable import DCTMultiAnimationRendererImpl

// An item that does not animate (a built-in reaction in a message's button, an emoji while looping
// is off) gets its frame from the first-frame load. When that load ends without a frame, the layer
// registers with the renderer, whose cache entry then arrives, but the renderer only drew frames
// for items that play: the layer stayed empty for good, and a reaction button with it.

private func makeItem(frameCount: Int) -> AnimationCacheItem {
    var index = -1
    return AnimationCacheItem(numFrames: frameCount, advanceImpl: { advance, _ in
        var didLoop = false
        let steps: Int
        switch advance {
        case let .frames(count):
            steps = count
        case .duration:
            steps = 1
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
        return AnimationCacheItem.AdvanceResult(frame: AnimationCacheItemFrame(format: .rgba(data: data, width: 16, height: 16, bytesPerRow: 64), duration: 1.0 / 30.0), didLoop: didLoop)
    }, resetImpl: {
        index = -1
    })
}

// "Not ready" first, like DCTAnimationCacheImpl on a miss; the item when the test completes it.
private final class PendingAnimationCache: AnimationCache {
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

private final class StillTarget: MultiAnimationRenderTarget {
    var transitions = 0

    override func transitionToContents(_ contents: AnyObject, didLoop: Bool) {
        self.transitions += 1
        self.contents = contents
    }
}

private final class StillTestTicker {
    private(set) var interval: Double?

    func makeScheduler() -> DCTAnimationTickScheduler {
        return DCTAnimationTickScheduler(start: { [weak self] interval, _ in
            self?.interval = interval
            return { [weak self] in
                self?.interval = nil
            }
        })
    }
}

final class DCTMultiAnimationRendererStillItemTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: Double = 5.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    func testStillItemWithNoFrameGetsTheFirstFrameWhenItsEntryArrives() {
        let ticker = StillTestTicker()
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        let cache = PendingAnimationCache()
        let target = StillTarget()
        target.shouldBeAnimating = false
        let disposable = renderer.add(target: target, cache: cache, itemId: "reaction", unique: true, size: CGSize(width: 16, height: 16), fetch: { _ in EmptyDisposable })

        cache.complete(item: makeItem(frameCount: 30))
        self.spin(until: { target.contents != nil })
        XCTAssertNotNil(target.contents, "an item that does not play got no frame when its cache entry arrived")
        XCTAssertEqual(target.transitions, 1)
        XCTAssertNil(ticker.interval, "a still item does not start the timer")
        disposable.dispose()
    }

    func testStillItemThatShowsAFrameIsLeftAlone() {
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: StillTestTicker().makeScheduler())
        let cache = PendingAnimationCache()
        let target = StillTarget()
        let shown = UIGraphicsImageRenderer(size: CGSize(width: 2.0, height: 2.0)).image(actions: { _ in }).cgImage!
        target.contents = shown
        let disposable = renderer.add(target: target, cache: cache, itemId: "reaction", unique: true, size: CGSize(width: 16, height: 16), fetch: { _ in EmptyDisposable })

        cache.complete(item: makeItem(frameCount: 30))
        self.spin(until: { false }, timeout: 0.3)
        XCTAssertEqual(target.transitions, 0, "a layer showing its first frame already is not given it again")
        XCTAssertTrue((target.contents as AnyObject?) === shown)
        disposable.dispose()
    }

    // As InlineStickerItemLayer without a synchronous load, with the real cache: the first-frame
    // conversion fails, so the layer registers with the renderer, and the full conversion succeeds.
    func testFirstFrameLoadFailureThenFullConversionShowsAFrame() {
        let basePath = NSTemporaryDirectory() + "dct-renderer-still-" + UUID().uuidString
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
        let fetch: (AnimationCacheFetchOptions) -> Disposable = { options in
            let writer = options.writer
            writer.queue.async {
                if options.firstFrameOnly {
                    // Nothing written: the first-frame conversion fails.
                    writer.finish()
                    return
                }
                for index in 0 ..< 10 {
                    writer.add(with: { surface in
                        for y in 0 ..< surface.height {
                            let row = surface.argb.advanced(by: y * surface.bytesPerRow)
                            for x in 0 ..< surface.width {
                                row[x * 4 + 0] = 255
                                row[x * 4 + 1] = UInt8(truncatingIfNeeded: index * 10)
                                row[x * 4 + 2] = 0
                                row[x * 4 + 3] = 255
                            }
                        }
                        return 1.0 / 30.0
                    }, proposedWidth: size, proposedHeight: size, insertKeyframe: index == 0)
                }
                writer.finish()
            }
            return EmptyDisposable
        }

        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: StillTestTicker().makeScheduler())
        let target = StillTarget()
        target.shouldBeAnimating = false

        var firstFrameResult: Bool?
        var addDisposable: Disposable?
        let firstFrameDisposable = renderer.loadFirstFrame(target: target, cache: cache, itemId: "reaction", size: CGSize(width: size, height: size), fetch: fetch, completion: { result, isFinal in
            guard isFinal else {
                return
            }
            firstFrameResult = result
            addDisposable = renderer.add(target: target, cache: cache, itemId: "reaction", unique: true, size: CGSize(width: size, height: size), fetch: fetch)
        })
        self.spin(until: { firstFrameResult != nil })
        XCTAssertEqual(firstFrameResult, false, "the first-frame conversion was meant to fail")
        XCTAssertNil(target.contents)

        self.spin(until: { target.contents != nil }, timeout: 10.0)
        XCTAssertNotNil(target.contents, "the full conversion finished, but the still layer stayed empty")
        firstFrameDisposable.dispose()
        addDisposable?.dispose()
    }
}
