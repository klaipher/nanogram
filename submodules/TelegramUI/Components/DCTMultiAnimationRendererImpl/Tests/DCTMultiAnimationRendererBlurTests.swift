import Foundation
import UIKit
import XCTest
import SwiftSignalKit
import AnimationCache
import MultiAnimationRenderer
@testable import DCTMultiAnimationRendererImpl

// Frames whose pixels differ per index, so their blurred badges differ too.
private final class GradientAnimationCache: AnimationCache {
    let frameCount = 12

    static func frame(index: Int) -> AnimationCacheItemFrame {
        let width = 32, height = 32, bytesPerRow = 128
        var data = Data(count: bytesPerRow * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * 4
                data[offset + 0] = UInt8((x * 8 + index * 20) & 0xff)
                data[offset + 1] = UInt8((y * 8) & 0xff)
                data[offset + 2] = UInt8((index * 37) & 0xff)
                data[offset + 3] = 255
            }
        }
        return AnimationCacheItemFrame(format: .rgba(data: data, width: width, height: height, bytesPerRow: bytesPerRow), duration: 1.0 / 30.0)
    }

    func makeItem() -> AnimationCacheItem {
        var index = -1
        let frameCount = self.frameCount
        return AnimationCacheItem(numFrames: frameCount, advanceImpl: { advance, _ in
            var didLoop = false
            let steps: Int
            switch advance {
            case let .frames(count):
                steps = count
            case let .duration(duration):
                steps = max(1, Int((duration * 30.0).rounded()))
            }
            for _ in 0 ..< steps {
                index += 1
                if index >= frameCount {
                    index = 0
                    didLoop = true
                }
            }
            return AnimationCacheItem.AdvanceResult(frame: GradientAnimationCache.frame(index: index), didLoop: didLoop)
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

// Remembers which frame (by its red channel at the origin) it shows and the badge it got with it.
private final class BadgeTarget: MultiAnimationRenderTarget {
    var shownFrames: [(frameIndexKey: UInt8, badge: CGImage?)] = []

    override func transitionToContents(_ contents: AnyObject, didLoop: Bool) {
        let image = contents as! CGImage
        let key = pixelBytes(image)[2]
        self.shownFrames.append((key, nil))
    }
}

private func pixelBytes(_ image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return bytes
}

private final class ManualTicker {
    private(set) var interval: Double?
    private var tick: ((Double) -> Void)?

    func makeScheduler() -> DCTAnimationTickScheduler {
        return DCTAnimationTickScheduler(start: { [weak self] interval, tick in
            self?.interval = interval
            self?.tick = tick
            return { [weak self] in
                self?.interval = nil
                self?.tick = nil
            }
        })
    }

    func fire() {
        self.tick?(self.interval ?? 0.0)
    }
}

/// The blurred badge behind locked premium emoji is made for every animation frame. It used to be made on the main
/// thread when the frame was applied (about 5% of main while the emoji panel was open); it is now made with the
/// frame on the loading queue, and main only assigns it.
final class DCTMultiAnimationRendererBlurTests: XCTestCase {
    private func spin(until condition: () -> Bool, timeout: Double = 10.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    func testBadgeIsMadeOffMainWithTheSamePixels() {
        let ticker = ManualTicker()
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        let target = BadgeTarget()
        let badgeLayer = CALayer()
        let color = UIColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1.0)
        target.blurredRepresentationBackgroundColor = color
        target.blurredRepresentationTarget = badgeLayer
        target.shouldBeAnimating = true
        let disposable = renderer.add(target: target, cache: GradientAnimationCache(), itemId: "premium", unique: false, size: CGSize(width: 32, height: 32), fetch: { _ in EmptyDisposable })
        self.spin(until: { ticker.interval != nil })

        let mainBuildsBefore = ItemAnimationContext.Frame.mainThreadBlurredRepresentationBuildsForTesting
        for _ in 0 ..< 24 {
            let shown = target.shownFrames.count
            ticker.fire()
            self.spin(until: { renderer.pendingFrameLoadsForTesting == 0 && target.shownFrames.count > shown })
            guard let badge = badgeLayer.contents else {
                XCTFail("no badge")
                break
            }
            target.shownFrames[target.shownFrames.count - 1].badge = (badge as! CGImage)
        }
        XCTAssertEqual(ItemAnimationContext.Frame.mainThreadBlurredRepresentationBuildsForTesting - mainBuildsBefore, 0, "badges made on main")
        XCTAssertGreaterThanOrEqual(target.shownFrames.count, 24)

        // Same pixels as making the badge from that frame directly.
        var expectedByKey: [UInt8: [UInt8]] = [:]
        for index in 0 ..< 12 {
            let frame = ItemAnimationContext.Frame(frame: GradientAnimationCache.frame(index: index))!
            expectedByKey[pixelBytes(frame.contentsAsImage!.cgImage!)[2]] = pixelBytes(frame.blurredRepresentation(color: color)!.cgImage!)
        }
        for shown in target.shownFrames {
            guard let badge = shown.badge else {
                continue
            }
            XCTAssertEqual(pixelBytes(badge), expectedByKey[shown.frameIndexKey])
        }
        disposable.dispose()
    }

    // Benchmark: the badge cost that left main, per frame.
    func testBenchmarkBadgeCost() {
        let frames = (0 ..< 12).map { GradientAnimationCache.frame(index: $0) }
        var best = Double.infinity
        for _ in 0 ..< 5 {
            let start = CACurrentMediaTime()
            for frame in frames {
                _ = ItemAnimationContext.Frame(frame: frame)!.blurredRepresentation(color: .white)
            }
            best = min(best, (CACurrentMediaTime() - start) / Double(frames.count))
        }
        print("BENCH premium badge blur per frame (32x32 source): \(String(format: "%.1f", best * 1_000_000.0)) us, now off main")
    }
}
