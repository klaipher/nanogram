import Foundation
import XCTest
import SwiftSignalKit
import VP9Hardware
import Compression
import CoreMedia
import Display
import YuvConversion
import UniversalMediaPlayer
@testable import AnimatedStickerNode

private func fixture(_ name: String, _ type: String) -> String? {
    let bundles = [Bundle(for: VideoStickerFrameCacheTests.self), Bundle.main] + Bundle.allBundles
    return bundles.lazy.compactMap({ $0.path(forResource: name, ofType: type) }).first
}

// cacheVideoStickerFrames (TelegramAnimatedStickerNode) as it was before the hardware decoder was
// used, kept here as the golden reference.
private func previousVideoStickerFrameCache(path: String, size: CGSize) -> Data {
    let source = SoftwareVideoSource(path: path, hintVP9: true, unpremultiplyAlpha: true)
    let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: Int(size.width))
    var currentFrame: Int32 = 0
    var output = Data()
    func writeData(_ data: UnsafeRawPointer, length: Int) {
        output.append(data.assumingMemoryBound(to: UInt8.self), count: length)
    }
    var fps: Int32 = Int32(min(30, source.getFramerate()))
    var frameCount: Int32 = 0
    writeData(&fps, length: 4)
    writeData(&frameCount, length: 4)
    var widthValue: Int32 = Int32(size.width)
    var heightValue: Int32 = Int32(size.height)
    var bytesPerRowValue: Int32 = Int32(bytesPerRow)
    writeData(&widthValue, length: 4)
    writeData(&heightValue, length: 4)
    writeData(&bytesPerRowValue, length: 4)
    let frameLength = bytesPerRow * Int(size.height)
    let yuvaPixelsPerAlphaRow = (Int(size.width) + 1) & (~1)
    let yuvaLength = Int(size.width) * Int(size.height) * 2 + yuvaPixelsPerAlphaRow * Int(size.height) / 2
    var yuvaFrameData = malloc(yuvaLength)!
    memset(yuvaFrameData, 0, yuvaLength)
    var previousYuvaFrameData = malloc(yuvaLength)!
    memset(previousYuvaFrameData, 0, yuvaLength)
    defer {
        free(previousYuvaFrameData)
        free(yuvaFrameData)
    }
    var compressedFrameData = Data(count: frameLength)
    let compressedFrameDataLength = compressedFrameData.count
    let scratchData = malloc(compression_encode_scratch_buffer_size(COMPRESSION_LZFSE))!
    defer {
        free(scratchData)
    }
    var process = true
    while process {
        let frameAndLoop = source.readFrame(maxPts: nil)
        if frameAndLoop.0 == nil {
            if frameAndLoop.3 {
                frameCount = currentFrame
                process = false
            }
            break
        }
        guard let frame = frameAndLoop.0 else {
            break
        }
        let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer)
        CVPixelBufferLockBaseAddress(imageBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        let originalBytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer!)
        let originalWidth = CVPixelBufferGetWidth(imageBuffer!)
        let originalHeight = CVPixelBufferGetHeight(imageBuffer!)
        if let srcBuffer = CVPixelBufferGetBaseAddress(imageBuffer!) {
            resizeAndEncodeRGBAToYUVA(yuvaFrameData.assumingMemoryBound(to: UInt8.self), srcBuffer.assumingMemoryBound(to: UInt8.self), Int32(size.width), Int32(size.height), Int32(bytesPerRow), Int32(originalWidth), Int32(originalHeight), Int32(originalBytesPerRow), false)
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        let lhs = previousYuvaFrameData.assumingMemoryBound(to: UInt8.self)
        let rhs = yuvaFrameData.assumingMemoryBound(to: UInt8.self)
        for i in 0 ..< yuvaLength {
            lhs[i] = rhs[i] ^ lhs[i]
        }
        compressedFrameData.withUnsafeMutableBytes { buffer -> Void in
            let bytes = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let length = compression_encode_buffer(bytes, compressedFrameDataLength, previousYuvaFrameData.assumingMemoryBound(to: UInt8.self), yuvaLength, scratchData, COMPRESSION_LZFSE)
            var frameLengthValue: Int32 = Int32(length)
            writeData(&frameLengthValue, length: 4)
            writeData(bytes, length: length)
        }
        let tmp = previousYuvaFrameData
        previousYuvaFrameData = yuvaFrameData
        yuvaFrameData = tmp
        currentFrame += 1
    }
    if frameCount > 0 {
        let _ = output.withUnsafeMutableBytes { buffer in
            memcpy(buffer.baseAddress!.advanced(by: 4), &frameCount, 4)
        }
    }
    return output
}

// The `.cached` video-sticker frame file (CachedVideoStickerRepresentation) is now decoded with the
// hardware VP9 decoder when there is one, falling back to libvpx, and must not change.
final class VideoStickerFrameCacheTests: XCTestCase {
    private let queue = Queue(name: "VideoStickerFrameCacheTests")
    private var savedFactory: ((String) -> VideoStickerHardwareStream?)?
    private let size = CGSize(width: 160.0, height: 160.0)

    override func setUp() {
        super.setUp()
        installTestLogger
        self.savedFactory = makeVideoStickerHardwareStream
    }

    override func tearDown() {
        if let savedFactory = self.savedFactory {
            makeVideoStickerHardwareStream = savedFactory
        }
        super.tearDown()
    }

    private func decodeFrames(_ data: Data) -> [Data] {
        var frames: [Data] = []
        self.queue.sync {
            guard let source = AnimatedStickerCachedFrameSource(queue: self.queue, data: data, complete: true, notifyUpdated: {}) else {
                return
            }
            XCTAssertEqual(source.frameCount, 24)
            for _ in 0 ..< source.frameCount {
                guard let frame = source.takeFrame(draw: true) else {
                    break
                }
                frames.append(frame.data)
            }
        }
        return frames
    }

    private func libvpxCache() throws -> Data {
        let path = try XCTUnwrap(fixture("sticker_vp9", "webm"))
        makeVideoStickerHardwareStream = { _ in nil }
        return try XCTUnwrap(makeVideoStickerFrameCache(path: path, size: self.size, isCancelled: { false }))
    }

    // The writer moved out of TelegramAnimatedStickerNode; its libvpx output is unchanged.
    func testLibvpxFileIsTheFileThePreviousWriterWrote() throws {
        let path = try XCTUnwrap(fixture("sticker_vp9", "webm"))
        let current = try self.libvpxCache()
        let previous = previousVideoStickerFrameCache(path: path, size: self.size)
        XCTAssertEqual(current.count, previous.count)
        XCTAssertTrue(current == previous, "the libvpx path wrote a different file")
        let frames = self.decodeFrames(current)
        XCTAssertEqual(frames.count, 24)
    }

    // Golden test: the hardware path writes byte for byte the file libvpx writes.
    func testHardwarePathWritesTheSameFile() throws {
        let path = try XCTUnwrap(fixture("sticker_vp9", "webm"))
        let expected = try self.libvpxCache()

        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        var decoder: LibvpxBackedDecoder?
        makeVideoStickerHardwareStream = { path in
            let instance = LibvpxBackedDecoder(path: path, failAt: nil)
            decoder = instance
            return VideoStickerHardwareStream(frames: sticker.frames, decoder: instance)
        }
        let actual = try XCTUnwrap(makeVideoStickerFrameCache(path: path, size: self.size, isCancelled: { false }))
        XCTAssertNil(decoder?.failure)
        XCTAssertEqual(decoder?.decodedCount, 24)
        XCTAssertEqual(decoder?.invalidated, true, "the hardware sessions must be released")
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertTrue(actual == expected, "the hardware path wrote a different file")
    }

    // A hardware error part way through writes the libvpx file.
    func testHardwareFailureFallsBackToLibvpx() throws {
        let path = try XCTUnwrap(fixture("sticker_vp9", "webm"))
        let expected = try self.libvpxCache()

        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        var decoder: LibvpxBackedDecoder?
        makeVideoStickerHardwareStream = { path in
            let instance = LibvpxBackedDecoder(path: path, failAt: 7)
            decoder = instance
            return VideoStickerHardwareStream(frames: sticker.frames, decoder: instance)
        }
        let actual = try XCTUnwrap(makeVideoStickerFrameCache(path: path, size: self.size, isCancelled: { false }))
        XCTAssertEqual(decoder?.decodedCount, 7)
        XCTAssertEqual(decoder?.invalidated, true)
        XCTAssertTrue(actual == expected, "the fallback wrote a different file")
    }

    // Not an assertion on speed: the codec's share of writing and reading one sticker, per codec,
    // on the sticker's real frame deltas (best of 30 alternating runs).
    func testCodecCost() throws {
        let path = try XCTUnwrap(fixture("sticker_vp9", "webm"))
        makeVideoStickerHardwareStream = { _ in nil }
        let legacy = try XCTUnwrap(makeVideoStickerFrameCache(path: path, size: self.size, isCancelled: { false }))
        let current = try XCTUnwrap(makeVideoStickerFrameCache(path: path, size: self.size, isCancelled: { false }))

        // The raw XOR deltas, taken from the LZFSE file.
        let yuvaLength = 160 * 160 * 2 + 160 * 160 / 2
        var deltas: [Data] = []
        var offset = 20
        while offset + 4 <= legacy.count {
            var length: Int32 = 0
            _ = withUnsafeMutableBytes(of: &length) { legacy.copyBytes(to: $0, from: offset ..< offset + 4) }
            offset += 4
            var delta = Data(count: yuvaLength)
            let decoded = delta.withUnsafeMutableBytes { out in
                legacy.withUnsafeBytes { bytes in
                    compression_decode_buffer(out.baseAddress!.assumingMemoryBound(to: UInt8.self), yuvaLength, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), Int(length), nil, COMPRESSION_LZFSE)
                }
            }
            XCTAssertEqual(decoded, yuvaLength)
            deltas.append(delta)
            offset += Int(length)
        }
        XCTAssertEqual(deltas.count, 24)

        var best: [String: (encode: Double, decode: Double)] = [:]
        var sizes: [String: Int] = [:]
        var output = Data(count: yuvaLength * 2)
        var roundTrip = Data(count: yuvaLength)
        for _ in 0 ..< 30 {
            for (name, algorithm) in [("lzfse", COMPRESSION_LZFSE), ("lz4", COMPRESSION_LZ4), ("lzbitmap", COMPRESSION_LZBITMAP), ("lzmesh", COMPRESSION_LZMESH), ("zlib", COMPRESSION_ZLIB)] {
                if name == "lzmesh", #unavailable(iOS 27.0) {
                    continue
                }
                var lengths: [Int] = []
                var encodeTime = 0.0
                var decodeTime = 0.0
                for delta in deltas {
                    let start = CFAbsoluteTimeGetCurrent()
                    let length = output.withUnsafeMutableBytes { out in
                        delta.withUnsafeBytes { input in
                            compression_encode_buffer(out.baseAddress!.assumingMemoryBound(to: UInt8.self), out.count, input.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count, nil, algorithm)
                        }
                    }
                    let middle = CFAbsoluteTimeGetCurrent()
                    let _ = roundTrip.withUnsafeMutableBytes { out in
                        output.withUnsafeBytes { input in
                            compression_decode_buffer(out.baseAddress!.assumingMemoryBound(to: UInt8.self), out.count, input.baseAddress!.assumingMemoryBound(to: UInt8.self), length, nil, algorithm)
                        }
                    }
                    decodeTime += CFAbsoluteTimeGetCurrent() - middle
                    encodeTime += middle - start
                    lengths.append(length)
                }
                sizes[name] = lengths.reduce(0, +)
                let previous = best[name] ?? (Double.infinity, Double.infinity)
                best[name] = (min(previous.encode, encodeTime), min(previous.decode, decodeTime))
            }
        }
        for name in ["lzfse", "lz4", "lzbitmap", "lzmesh", "zlib"] {
            guard let value = best[name] else {
                continue
            }
            print("VideoStickerFrameCache codec \(name): \(sizes[name] ?? 0) bytes, encode 24 frames \(String(format: "%.2f", value.encode * 1000.0)) ms, decode \(String(format: "%.2f", value.decode * 1000.0)) ms")
        }
    }
}
