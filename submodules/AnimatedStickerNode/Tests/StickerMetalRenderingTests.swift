import Foundation
import UIKit
import XCTest
import AsyncDisplayKit
import Metal
import SwiftSignalKit
import Display
import LottieSettings
@testable import AnimatedStickerNode

private func log(_ string: String) {
    FileHandle.standardError.write(Data((string + "\n").utf8))
}

private func onQueue<T>(_ queue: Queue, _ f: () -> T) -> T {
    var result: [T] = []
    queue.sync {
        result.append(f())
    }
    return result[0]
}

// Spins the main run loop: the Metal cache and renderer finish on the main queue.
private func spinUntil(timeout: Double = 20.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

private func tableEntryLength(path: String, index: Int) -> Int {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= index * 8 + 8 else {
        return 0
    }
    var length: Int32 = 0
    _ = withUnsafeMutableBytes(of: &length) { data.copyBytes(to: $0, from: index * 8 + 4 ..< index * 8 + 8) }
    return Int(length)
}

// Premultiplied BGRA, tightly packed, in the device colour space: the format rlottie renders into.
private func pixels(of image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var result = [UInt8](repeating: 0, count: width * height * 4)
    result.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: DeviceGraphicsContextSettings.shared.colorSpace, bitmapInfo: DeviceGraphicsContextSettings.shared.transparentBitmapInfo.rawValue) else {
            return
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return result
}

private func packedPixels(of frame: AnimatedStickerFrame) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
    frame.data.withUnsafeBytes { source in
        for y in 0 ..< frame.height {
            for x in 0 ..< frame.width * 4 {
                result[y * frame.width * 4 + x] = source[y * frame.bytesPerRow + x]
            }
        }
    }
    return result
}

private struct PixelDifference {
    var mean: Double
    var max: Int
    // Share of channel values more than 16/255 off.
    var outliers: Double
}

private func difference(_ lhs: [UInt8], _ rhs: [UInt8]) -> PixelDifference {
    precondition(lhs.count == rhs.count)
    var sum = 0
    var maxValue = 0
    var outliers = 0
    for i in 0 ..< lhs.count {
        let value = abs(Int(lhs[i]) - Int(rhs[i]))
        sum += value
        maxValue = max(maxValue, value)
        if value > 16 {
            outliers += 1
        }
    }
    return PixelDifference(mean: Double(sum) / Double(lhs.count), max: maxValue, outliers: Double(outliers) / Double(lhs.count))
}

final class StickerMetalRenderingTests: XCTestCase {
    private var directory = ""

    override func setUp() {
        super.setUp()
        self.directory = NSTemporaryDirectory() + "sticker-metal-tests-" + UUID().uuidString
        XCTAssertNoThrow(try FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    // The Bazel test runner runs this bundle as a logic test, where the simulator gives the process
    // no Metal device (MTLCreateSystemDefaultDevice() is nil; checked 2026-11-01, iOS 27.2). A hosted
    // variant stalled in xcodebuild before its first test, so these tests run where a device exists
    // and skip, loudly, where none does. AnimationCompressor.SharedContext.shared traps without one.
    private func requireMetalDevice() throws {
        if MTLCreateSystemDefaultDevice() == nil {
            log("METAL no device in this test process: Metal rendering tests skipped")
            throw XCTSkip("no Metal device in this test process")
        }
    }

    private func loadSticker() throws -> Data {
        let bundles = [Bundle(for: StickerMetalRenderingTests.self), Bundle.main] + Bundle.allBundles
        let path = try XCTUnwrap(bundles.lazy.compactMap({ $0.path(forResource: "Slot_M_Berries", ofType: "tgs") }).first, "fixture missing")
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func render(_ frame: AnimatedStickerFrame, with renderer: CompressedAnimationRenderer, queue: Queue) -> CGImage? {
        var completed = false
        renderer.render(queue: queue, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: frame.data, type: frame.type, mulAlpha: frame.multiplyAlpha, completion: {
            completed = true
        }, averageColor: nil)
        XCTAssertTrue(spinUntil { completed }, "renderer completion")
        guard let contents = renderer.layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (contents as! CGImage)
    }

    // A real sticker through the dormant GPU path: rlottie frame -> Metal DCT cache (-mtl file)
    // -> CompressedAnimationRenderer, compared with the frame the CPU path starts from.
    func testMetalCacheAndRendererMatchCPUFrame() throws {
        try self.requireMetalDevice()
        let sticker = try self.loadSticker()
        let queue = Queue()
        let prefix = self.directory + "/sticker"
        // 250 is not a multiple of 16: the Metal cache renders it at 256.
        var sourceValue: AnimatedStickerDirectFrameSource? = onQueue(queue) {
            AnimatedStickerDirectFrameSource(queue: queue, data: sticker, width: 250, height: 250, cachePathPrefix: prefix, useMetalCache: true, fitzModifier: nil, lottieSettings: .noAccountFallback)
        }
        defer {
            queue.sync {
                sourceValue = nil
            }
        }
        let source = try XCTUnwrap(sourceValue)
        let frameIndex = source.frameCount / 2

        let cpuFrame = try XCTUnwrap(onQueue(queue) { () -> AnimatedStickerFrame? in
            source.skipToFrameIndex(frameIndex)
            return source.takeFrame(draw: true)
        })
        XCTAssertEqual(cpuFrame.type, .argb)
        XCTAssertEqual(cpuFrame.width, 256)
        XCTAssertEqual(cpuFrame.height, 256)
        let expected = packedPixels(of: cpuFrame)
        XCTAssertGreaterThan(stride(from: 3, to: expected.count, by: 4).filter { expected[$0] != 0 }.count, 256 * 256 / 10, "the sticker frame is mostly empty")

        // The frame was handed to the Metal compressor; wait for it to land in the -mtl cache file.
        let cachePath = AnimatedStickerDirectFrameSourceCache.path(pathPrefix: prefix, width: 256, height: 256, suffix: "", version: AnimatedStickerDirectFrameSourceCache.version, useHardware: true)
        XCTAssertTrue(spinUntil { onQueue(queue) { tableEntryLength(path: cachePath, index: frameIndex) } > 0 }, "the Metal cache stored no frame")

        let dctFrame = try XCTUnwrap(onQueue(queue) { () -> AnimatedStickerFrame? in
            source.skipToFrameIndex(frameIndex)
            return source.takeFrame(draw: true)
        })
        XCTAssertEqual(dctFrame.type, .dct)
        log("METAL stickerframe dct bytes=\(dctFrame.data.count) argb bytes=\(cpuFrame.data.count)")

        let renderer = CompressedAnimationRenderer()
        renderer.frame = CGRect(x: 0.0, y: 0.0, width: 256.0, height: 256.0)

        // Uncached frames reach the Metal renderer as ARGB: that path must be (near) exact.
        let rgbImage = try XCTUnwrap(self.render(cpuFrame, with: renderer, queue: queue))
        XCTAssertEqual(rgbImage.width, 256)
        XCTAssertEqual(rgbImage.height, 256)
        let rgbDifference = difference(pixels(of: rgbImage), expected)
        log(String(format: "METAL argb vs cpu: mean=%.3f max=%d outliers=%.5f", rgbDifference.mean, rgbDifference.max, rgbDifference.outliers))
        XCTAssertLessThanOrEqual(rgbDifference.max, 2)

        // Cached frames are DCT: lossy, so compare within a tolerance.
        let dctImage = try XCTUnwrap(self.render(dctFrame, with: renderer, queue: queue))
        XCTAssertEqual(dctImage.width, 256)
        XCTAssertEqual(dctImage.height, 256)
        let dctDifference = difference(pixels(of: dctImage), expected)
        log(String(format: "METAL dct vs cpu: mean=%.3f max=%d outliers=%.5f", dctDifference.mean, dctDifference.max, dctDifference.outliers))
        XCTAssertLessThan(dctDifference.mean, 3.0)
        XCTAssertLessThan(dctDifference.outliers, 0.02)
    }

    // The CPU cache's YUVA frames, which `.cached` sources and video stickers also produce, through
    // the Metal renderer.
    func testMetalRendererDrawsYuvaFrame() throws {
        try self.requireMetalDevice()
        let sticker = try self.loadSticker()
        let queue = Queue()
        let prefix = self.directory + "/sticker"
        var sourceValue: AnimatedStickerDirectFrameSource? = onQueue(queue) {
            AnimatedStickerDirectFrameSource(queue: queue, data: sticker, width: 256, height: 256, cachePathPrefix: prefix, useMetalCache: false, fitzModifier: nil, lottieSettings: .noAccountFallback)
        }
        defer {
            queue.sync {
                sourceValue = nil
            }
        }
        let source = try XCTUnwrap(sourceValue)
        let frameIndex = source.frameCount / 2
        let cpuFrame = try XCTUnwrap(onQueue(queue) { () -> AnimatedStickerFrame? in
            source.skipToFrameIndex(frameIndex)
            return source.takeFrame(draw: true)
        })
        let cachePath = AnimatedStickerDirectFrameSourceCache.path(pathPrefix: prefix, width: 256, height: 256, suffix: "", version: AnimatedStickerDirectFrameSourceCache.version, useHardware: false)
        XCTAssertTrue(spinUntil { onQueue(queue) { tableEntryLength(path: cachePath, index: frameIndex) } > 0 })
        let yuvaFrame = try XCTUnwrap(onQueue(queue) { () -> AnimatedStickerFrame? in
            source.skipToFrameIndex(frameIndex)
            return source.takeFrame(draw: true)
        })
        XCTAssertEqual(yuvaFrame.type, .yuva)

        let renderer = CompressedAnimationRenderer()
        renderer.frame = CGRect(x: 0.0, y: 0.0, width: 256.0, height: 256.0)
        let image = try XCTUnwrap(self.render(yuvaFrame, with: renderer, queue: queue))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
        let yuvaDifference = difference(pixels(of: image), packedPixels(of: cpuFrame))
        log(String(format: "METAL yuva vs cpu: mean=%.3f max=%d outliers=%.5f", yuvaDifference.mean, yuvaDifference.max, yuvaDifference.outliers))
        XCTAssertLessThan(yuvaDifference.mean, 3.0)
        XCTAssertLessThan(yuvaDifference.outliers, 0.02)
    }

    func testRendererSelection() {
        let small = (width: 160, height: 160)
        let large = (width: 384, height: 384)
        let wideChatSticker = (width: 384, height: 160)

        for explicitlyRequested in [false, true] {
            for size in [small, large] {
                XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .cpu, explicitlyRequested: explicitlyRequested, width: size.width, height: size.height), explicitlyRequested)
                XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .gpuAll, explicitlyRequested: explicitlyRequested, width: size.width, height: size.height), true)
            }
            XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .gpuLarge, explicitlyRequested: explicitlyRequested, width: large.width, height: large.height), true)
            XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .gpuLarge, explicitlyRequested: explicitlyRequested, width: wideChatSticker.width, height: wideChatSticker.height), true)
            XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .gpuLarge, explicitlyRequested: explicitlyRequested, width: small.width, height: small.height), explicitlyRequested)
        }

        // Before setup the size is unknown: only `.gpuLarge` has to wait for it.
        XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .cpu, explicitlyRequested: false, width: nil, height: nil), false)
        XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .gpuAll, explicitlyRequested: false, width: nil, height: nil), true)
        XCTAssertNil(animatedStickerUsesMetalRenderer(mode: .gpuLarge, explicitlyRequested: false, width: nil, height: nil))
        XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .gpuLarge, explicitlyRequested: true, width: nil, height: nil), true)

        // The threshold itself: 200x200 is large, one row less is not.
        XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .gpuLarge, explicitlyRequested: false, width: 200, height: 200), true)
        XCTAssertEqual(animatedStickerUsesMetalRenderer(mode: .gpuLarge, explicitlyRequested: false, width: 200, height: 199), false)
    }
}
