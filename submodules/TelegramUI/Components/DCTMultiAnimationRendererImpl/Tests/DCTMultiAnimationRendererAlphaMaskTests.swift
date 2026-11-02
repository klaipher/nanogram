import Foundation
import UIKit
import XCTest
import CoreVideo
import SwiftSignalKit
import AnimationCache
import MultiAnimationRenderer
@testable import DCTMultiAnimationRendererImpl

// A template emoji as the cache stores it: white, premultiplied, a disc of alpha 255 on alpha 0, in the
// format the renderer asks for. Frames differ only in the disc's radius.
private final class TemplateDiscAnimationCache: AnimationCache {
    let side: Int
    let frameCount = 8
    private(set) var requestedYuva = 0
    private(set) var requestedRgba = 0
    private let lock = NSLock()

    init(side: Int) {
        self.side = side
    }

    static func alpha(side: Int, index: Int, x: Int, y: Int) -> UInt8 {
        let radius = Double(side) / 3.0 + Double(index)
        let dx = Double(x) - Double(side) / 2.0 + 0.5
        let dy = Double(y) - Double(side) / 2.0 + 0.5
        return dx * dx + dy * dy < radius * radius ? 255 : 0
    }

    func frame(index: Int, format: AnimationCacheItemFrame.RequestedFormat) -> AnimationCacheItemFrame {
        let side = self.side
        switch format {
        case .rgba:
            self.lock.lock()
            self.requestedRgba += 1
            self.lock.unlock()
            var data = Data(count: side * side * 4)
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let a = TemplateDiscAnimationCache.alpha(side: side, index: index, x: x, y: y)
                    let offset = (y * side + x) * 4
                    data[offset + 0] = a
                    data[offset + 1] = a
                    data[offset + 2] = a
                    data[offset + 3] = a
                }
            }
            return AnimationCacheItemFrame(format: .rgba(data: data, width: side, height: side, bytesPerRow: side * 4), duration: 1.0 / 30.0)
        case .yuva:
            self.lock.lock()
            self.requestedYuva += 1
            self.lock.unlock()
            var yData = Data(count: side * side)
            var aData = Data(count: side * side)
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let a = TemplateDiscAnimationCache.alpha(side: side, index: index, x: x, y: y)
                    // Premultiplied white: full-range luma equals alpha.
                    yData[y * side + x] = a
                    aData[y * side + x] = a
                }
            }
            let chroma = Data(repeating: 128, count: side / 2 * side / 2)
            return AnimationCacheItemFrame(format: .yuva(
                y: AnimationCacheItemFrame.Plane(data: yData, width: side, height: side, bytesPerRow: side),
                u: AnimationCacheItemFrame.Plane(data: chroma, width: side / 2, height: side / 2, bytesPerRow: side / 2),
                v: AnimationCacheItemFrame.Plane(data: chroma, width: side / 2, height: side / 2, bytesPerRow: side / 2),
                a: AnimationCacheItemFrame.Plane(data: aData, width: side, height: side, bytesPerRow: side)
            ), duration: 1.0 / 30.0)
        }
    }

    func makeItem() -> AnimationCacheItem {
        var index = -1
        let frameCount = self.frameCount
        return AnimationCacheItem(numFrames: frameCount, advanceImpl: { [weak self] advance, format in
            guard let self else {
                return nil
            }
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
            return AnimationCacheItem.AdvanceResult(frame: self.frame(index: index, format: format), didLoop: didLoop)
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

private final class RecordingTarget: MultiAnimationRenderTarget {
    var delivered: [AnyObject] = []

    override func transitionToContents(_ contents: AnyObject, didLoop: Bool) {
        self.delivered.append(contents)
        self.contents = contents
    }
}

private final class ManualTicker {
    private(set) var interval: Double?
    private var tick: (() -> Void)?

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
        self.tick?()
    }
}

private func isPixelBuffer(_ value: AnyObject) -> Bool {
    return CFGetTypeID(value as CFTypeRef) == CVPixelBufferGetTypeID()
}

private func isImage(_ value: AnyObject) -> Bool {
    return CFGetTypeID(value as CFTypeRef) == CGImage.typeID
}

// Premultiplied BGRA of an image, rows from the top.
private func bgraBytes(_ image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return bytes
}

private func alphaValues(_ image: CGImage) -> [UInt8] {
    let bytes = bgraBytes(image)
    return (0 ..< image.width * image.height).map { bytes[$0 * 4 + 3] }
}

/// A template emoji (an emoji status in the profile header or the status sheet) is tinted by drawing only
/// its alpha (contentsSwizzle "AAAA"). Core Animation reads alpha as 1 from the YUVA surface under that
/// swizzle, so with "Emoji: GPU renderer (YUVA)" on, every one at least 128 px was a solid square of the
/// tint colour (reproduced with CARenderer on the Mac: 16384 of 16384 pixels covered against 5721 for the
/// image). Such targets must get images; untinted ones keep the YUVA surface.
final class DCTMultiAnimationRendererAlphaMaskTests: XCTestCase {
    private let side = 160

    private func spin(until condition: () -> Bool, timeout: Double = 10.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func play(renderer: DCTMultiAnimationRendererImpl, ticker: ManualTicker, target: RecordingTarget, ticks: Int) {
        self.spin(until: { ticker.interval != nil })
        for _ in 0 ..< ticks {
            let count = target.delivered.count
            ticker.fire()
            self.spin(until: { renderer.pendingFrameLoadsForTesting == 0 && target.delivered.count > count })
        }
    }

    private func assertDisc(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        let alpha = alphaValues(image)
        XCTAssertEqual(image.width, self.side, file: file, line: line)
        // Corners transparent, centre opaque: not a square.
        XCTAssertEqual(alpha[0], 0, file: file, line: line)
        XCTAssertEqual(alpha[self.side * self.side - 1], 0, file: file, line: line)
        XCTAssertEqual(alpha[(self.side / 2) * self.side + self.side / 2], 255, file: file, line: line)
    }

    func testMaskedTargetIsGivenImagesWithTheirAlpha() throws {
        let ticker = ManualTicker()
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        renderer.useYuvA = true
        let cache = TemplateDiscAnimationCache(side: self.side)
        let target = RecordingTarget()
        target.contentsAlphaIsMask = true
        target.shouldBeAnimating = true
        let disposable = renderer.add(target: target, cache: cache, itemId: "status", unique: false, size: CGSize(width: self.side, height: self.side), fetch: { _ in EmptyDisposable })
        self.play(renderer: renderer, ticker: ticker, target: target, ticks: 12)

        XCTAssertGreaterThanOrEqual(target.delivered.count, 12)
        XCTAssertEqual(target.delivered.filter(isPixelBuffer).count, 0, "a YUVA surface reached a target that draws only alpha")
        for contents in target.delivered where isImage(contents) {
            self.assertDisc(contents as! CGImage)
        }
        disposable.dispose()
    }

    func testUntintedTargetKeepsTheYuvaSurface() {
        let ticker = ManualTicker()
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        renderer.useYuvA = true
        let cache = TemplateDiscAnimationCache(side: self.side)
        let target = RecordingTarget()
        target.shouldBeAnimating = true
        let disposable = renderer.add(target: target, cache: cache, itemId: "status", unique: false, size: CGSize(width: self.side, height: self.side), fetch: { _ in EmptyDisposable })
        self.play(renderer: renderer, ticker: ticker, target: target, ticks: 12)

        XCTAssertGreaterThanOrEqual(target.delivered.count, 12)
        XCTAssertEqual(target.delivered.filter(isPixelBuffer).count, target.delivered.count)
        XCTAssertEqual(cache.requestedRgba, 0)
        disposable.dispose()
    }

    // The tint can be set after a YUVA frame is shown, and a stopped animation brings no next frame.
    func testMaskSetWhileShowingAYuvaFrameReplacesIt() throws {
        let ticker = ManualTicker()
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        renderer.useYuvA = true
        let cache = TemplateDiscAnimationCache(side: self.side)
        let target = RecordingTarget()
        target.shouldBeAnimating = true
        let disposable = renderer.add(target: target, cache: cache, itemId: "status", unique: false, size: CGSize(width: self.side, height: self.side), fetch: { _ in EmptyDisposable })
        self.play(renderer: renderer, ticker: ticker, target: target, ticks: 3)
        target.shouldBeAnimating = false
        self.spin(until: { ticker.interval == nil })
        let shown = try XCTUnwrap(target.delivered.last)
        XCTAssertTrue(isPixelBuffer(shown))

        target.contentsAlphaIsMask = true
        self.spin(until: { target.delivered.last.map(isImage) ?? false }, timeout: 2.0)
        let replaced = try XCTUnwrap(target.delivered.last)
        XCTAssertTrue(isImage(replaced), "the YUVA frame stayed under the mask")
        if isImage(replaced) {
            self.assertDisc(replaced as! CGImage)
        }
        disposable.dispose()
    }

    // A target added to an item that is already showing a YUVA frame.
    func testMaskedTargetAddedToAPlayingItemGetsAnImage() throws {
        let ticker = ManualTicker()
        let renderer = DCTMultiAnimationRendererImpl(tickScheduler: ticker.makeScheduler())
        renderer.useYuvA = true
        let cache = TemplateDiscAnimationCache(side: self.side)
        let first = RecordingTarget()
        first.shouldBeAnimating = true
        let firstDisposable = renderer.add(target: first, cache: cache, itemId: "status", unique: false, size: CGSize(width: self.side, height: self.side), fetch: { _ in EmptyDisposable })
        self.play(renderer: renderer, ticker: ticker, target: first, ticks: 3)
        XCTAssertTrue(first.delivered.last.map(isPixelBuffer) ?? false)

        let second = RecordingTarget()
        second.contentsAlphaIsMask = true
        let secondDisposable = renderer.add(target: second, cache: cache, itemId: "status", unique: false, size: CGSize(width: self.side, height: self.side), fetch: { _ in EmptyDisposable })
        let added = try XCTUnwrap(second.delivered.first)
        XCTAssertTrue(isImage(added))
        if isImage(added) {
            self.assertDisc(added as! CGImage)
        }

        // While the masked target is there, the item plays images for both.
        let count = second.delivered.count
        ticker.fire()
        self.spin(until: { renderer.pendingFrameLoadsForTesting == 0 && second.delivered.count > count })
        XCTAssertTrue(second.delivered.last.map(isImage) ?? false)
        firstDisposable.dispose()
        secondDisposable.dispose()
    }

    // The image made from a YUVA frame for a masked target has the frame's alpha and the image path's colours.
    func testImageFromYuvaFrameKeepsAlphaAndColours() throws {
        let cache = TemplateDiscAnimationCache(side: 64)
        let yuva = ItemAnimationContext.Frame(frame: cache.frame(index: 2, format: .yuva(rowAlignment: 1)))
        let frame = try XCTUnwrap(yuva)
        XCTAssertNotNil(frame.contentsAsCVPixelBuffer)
        XCTAssertTrue(isPixelBuffer(try XCTUnwrap(frame.contents(alphaIsMask: false))))
        let masked = try XCTUnwrap(frame.contents(alphaIsMask: true))
        guard isImage(masked) else {
            XCTFail("a YUVA surface for a target that draws only alpha")
            return
        }
        let image = masked as! CGImage
        // The same image every time: it is made once per frame.
        XCTAssertTrue(frame.contents(alphaIsMask: true) === image)

        let alpha = alphaValues(image)
        var wrong = 0
        for y in 0 ..< 64 {
            for x in 0 ..< 64 where alpha[y * 64 + x] != TemplateDiscAnimationCache.alpha(side: 64, index: 2, x: x, y: y) {
                wrong += 1
            }
        }
        XCTAssertEqual(wrong, 0)

        let rgba = try XCTUnwrap(ItemAnimationContext.Frame(frame: cache.frame(index: 2, format: .rgba))?.contentsAsImage?.cgImage)
        let expected = bgraBytes(rgba)
        let actual = bgraBytes(image)
        var maxDifference = 0
        for i in 0 ..< expected.count {
            maxDifference = max(maxDifference, abs(Int(expected[i]) - Int(actual[i])))
        }
        XCTAssertLessThanOrEqual(maxDifference, 2)
    }
}
