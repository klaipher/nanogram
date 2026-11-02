import Foundation
import XCTest
import SwiftSignalKit
import YuvConversion
import AnimationCompression
@testable import AnimatedStickerNode

private func fixture(_ name: String, _ type: String) -> String? {
    let bundles = [Bundle(for: YuvaFrameLayoutTests.self), Bundle.main] + Bundle.allBundles
    return bundles.lazy.compactMap({ $0.path(forResource: name, ofType: type) }).first
}

/// The 4-bit alpha of every pixel, read from where `layout` says the alpha plane is: what the
/// Metal renderer uploads into its alpha texture and the YUVA shader reads.
private func alphaFromLayout(_ layout: YuvaFrameLayout, _ data: Data) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: layout.width * layout.height)
    data.withUnsafeBytes { bytes in
        for y in 0 ..< layout.height {
            for x in 0 ..< layout.width {
                let packed = bytes[layout.alphaOffset + y * layout.alphaBytesPerRow + x / 2]
                let nibble = x % 2 == 0 ? packed >> 4 : packed & 0x0f
                result[y * layout.width + x] = nibble | (nibble << 4)
            }
        }
    }
    return result
}

/// The alpha the CPU renderer draws for a YUVA frame (`SoftwareAnimationRenderer`).
private func alphaFromCpuDecoder(width: Int, height: Int, _ data: Data) -> [UInt8] {
    let bytesPerRow = width * 4
    var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
    data.withUnsafeBytes { source in
        bgra.withUnsafeMutableBytes { dest in
            guard let sourceAddress = source.baseAddress, let destAddress = dest.baseAddress else {
                return
            }
            decodeYUVAToRGBA(sourceAddress.assumingMemoryBound(to: UInt8.self), destAddress.assumingMemoryBound(to: UInt8.self), Int32(clamping: width), Int32(clamping: height), Int32(clamping: bytesPerRow))
        }
    }
    return (0 ..< width * height).map { bgra[$0 * 4 + 3] }
}

private func coverage(_ alpha: [UInt8]) -> Int {
    return alpha.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
}

final class YuvaFrameLayoutTests: XCTestCase {
    private let queue = Queue(name: "YuvaFrameLayoutTests")
    private var directory = ""

    override func setUp() {
        super.setUp()
        installTestLogger
        self.directory = NSTemporaryDirectory() + "yuva-layout-tests-" + UUID().uuidString
        XCTAssertNoThrow(try FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    // The Metal renderer reads the alpha plane where the CPU encoder writes it. It read it half a
    // luma plane early, from bytes the encoder never writes (zero): every YUVA frame, which video
    // stickers show from their second loop on, was drawn fully transparent.
    func testAlphaPlaneIsWhereTheEncoderWritesIt() {
        for (width, height) in [(384, 384), (400, 400), (384, 256), (160, 160), (2, 2)] {
            let bytesPerRow = width * 4
            var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
            var expected = [UInt8](repeating: 0, count: width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    // Opaque, transparent and partial alpha, in straight (not premultiplied) BGRA.
                    let alpha = UInt8(truncatingIfNeeded: (x * 7 + y * 3) % 256)
                    bgra[y * bytesPerRow + x * 4 + 0] = UInt8(truncatingIfNeeded: x)
                    bgra[y * bytesPerRow + x * 4 + 1] = UInt8(truncatingIfNeeded: y)
                    bgra[y * bytesPerRow + x * 4 + 2] = 200
                    bgra[y * bytesPerRow + x * 4 + 3] = alpha
                    expected[y * width + x] = (alpha >> 4) | ((alpha >> 4) << 4)
                }
            }
            let length = YuvaFrameLayout.length(width: width, height: height)
            var yuva = Data(count: length)
            yuva.withUnsafeMutableBytes { dest in
                bgra.withUnsafeMutableBytes { source in
                    guard let destAddress = dest.baseAddress, let sourceAddress = source.baseAddress else {
                        return
                    }
                    encodeRGBAToYUVA(destAddress.assumingMemoryBound(to: UInt8.self), sourceAddress.assumingMemoryBound(to: UInt8.self), Int32(clamping: width), Int32(clamping: height), Int32(clamping: bytesPerRow), true, false)
                }
            }
            guard let layout = YuvaFrameLayout(width: width, height: height, dataCount: yuva.count) else {
                XCTFail("no layout for \(width)x\(height)")
                continue
            }
            XCTAssertEqual(layout.lumaOffset, 0)
            XCTAssertEqual(layout.chromaOffset, width * height)
            XCTAssertLessThanOrEqual(layout.alphaOffset + layout.alphaBytesPerRow * height, yuva.count)
            XCTAssertEqual(alphaFromLayout(layout, yuva), expected, "\(width)x\(height): alpha read from the wrong place")
            XCTAssertEqual(alphaFromLayout(layout, yuva), alphaFromCpuDecoder(width: width, height: height, yuva), "\(width)x\(height): the CPU renderer draws another alpha")
        }
    }

    // The frame length is the one the caches allocate and decode (VideoStickerFrameSourceCache,
    // compressFrame), and short or odd frames have no layout.
    func testLengthAndRejectedFrames() {
        for (width, height) in [(384, 384), (384, 255), (255, 384), (161, 161)] {
            let yuvaPixelsPerAlphaRow = (width + 1) & (~1)
            XCTAssertEqual(YuvaFrameLayout.length(width: width, height: height), width * height * 2 + yuvaPixelsPerAlphaRow * height / 2)
        }
        let length = YuvaFrameLayout.length(width: 384, height: 384)
        XCTAssertNotNil(YuvaFrameLayout(width: 384, height: 384, dataCount: length))
        XCTAssertNil(YuvaFrameLayout(width: 384, height: 384, dataCount: length - 1))
        XCTAssertNil(YuvaFrameLayout(width: 384, height: 255, dataCount: YuvaFrameLayout.length(width: 384, height: 255)))
        XCTAssertNil(YuvaFrameLayout(width: 255, height: 384, dataCount: YuvaFrameLayout.length(width: 255, height: 384)))
        XCTAssertNil(YuvaFrameLayout(width: 0, height: 384, dataCount: length))
    }

    // Odd sizes (a sticker that is not square, fitted to 384 on its long side) are not drawn from
    // the planes; the Metal renderer decodes them as the CPU renderer does and draws BGRA.
    func testOddSizedFramesAreDecodedOnTheCpu() {
        XCTAssertEqual(compressedAnimationYuvaDrawing(width: 384, height: 384, dataCount: YuvaFrameLayout.length(width: 384, height: 384)), .planes)
        XCTAssertEqual(compressedAnimationYuvaDrawing(width: 384, height: 255, dataCount: YuvaFrameLayout.length(width: 384, height: 255)), .decodedBgra)
        XCTAssertEqual(compressedAnimationYuvaDrawing(width: 255, height: 384, dataCount: YuvaFrameLayout.length(width: 255, height: 384)), .decodedBgra)
        XCTAssertEqual(compressedAnimationYuvaDrawing(width: 384, height: 384, dataCount: 100), .none)
    }

    // A real video sticker (VP9 with alpha): the first loop is decoded (BGRA) and stored in the
    // frame cache, later loops are read from it as YUVA. The YUVA frame read through the layout
    // covers the same pixels as the decoded frame did.
    func testVideoStickerCachedFramesKeepTheirAlpha() throws {
        let path = try XCTUnwrap(fixture("sticker_vp9", "webm"))
        for (width, height) in [(384, 384), (400, 400), (384, 256)] {
            let prefix = self.directory + "/sticker-\(width)x\(height)"
            var firstLoop: [AnimatedStickerFrame] = []
            var sourceValue: VideoStickerDirectFrameSource?
            self.queue.sync {
                sourceValue = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: width, height: height, cachePathPrefix: prefix)
                while let source = sourceValue, firstLoop.count < 1000, let frame = source.takeFrame(draw: true), frame.type == .argb {
                    firstLoop.append(frame)
                }
            }
            defer {
                self.queue.sync {
                    sourceValue = nil
                }
            }
            let source = try XCTUnwrap(sourceValue)
            XCTAssertGreaterThan(firstLoop.count, 1)

            // The frames are stored on another queue; read one back once it is written.
            let index = firstLoop.count / 2
            var yuvaFrame: AnimatedStickerFrame?
            let deadline = Date().addingTimeInterval(20.0)
            while yuvaFrame == nil, Date() < deadline {
                self.queue.sync {
                    source.skipToFrameIndex(index)
                    if let frame = source.takeFrame(draw: true), frame.type == .yuva {
                        yuvaFrame = frame
                    }
                }
                if yuvaFrame == nil {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            let frame = try XCTUnwrap(yuvaFrame, "\(width)x\(height): no cached frame")
            XCTAssertEqual(frame.width, width)
            XCTAssertEqual(frame.height, height)
            let layout = try XCTUnwrap(YuvaFrameLayout(width: frame.width, height: frame.height, dataCount: frame.data.count))

            let decoded = firstLoop[index]
            let decodedAlpha: [UInt8] = (0 ..< width * height).map { i in
                decoded.data[(i / width) * decoded.bytesPerRow + (i % width) * 4 + 3]
            }
            let cachedAlpha = alphaFromLayout(layout, frame.data)
            let decodedCoverage = coverage(decodedAlpha.map { $0 >> 4 })
            XCTAssertGreaterThan(decodedCoverage, width * height / 20, "\(width)x\(height): the sticker frame is empty")
            XCTAssertLessThan(decodedCoverage, width * height, "\(width)x\(height): the sticker frame has no transparency")
            XCTAssertEqual(coverage(cachedAlpha), decodedCoverage, "\(width)x\(height): the cached frame's alpha covers other pixels")
            var maxDifference = 0
            for i in 0 ..< width * height {
                maxDifference = max(maxDifference, abs(Int(cachedAlpha[i]) - Int(decodedAlpha[i])))
            }
            // 4-bit alpha.
            XCTAssertLessThanOrEqual(maxDifference, 17, "\(width)x\(height)")
        }
    }
}
