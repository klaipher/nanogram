import Foundation
import XCTest
import Compression
import SwiftSignalKit
import YuvConversion
@testable import AnimatedStickerNode

private func log(_ string: String) {
    FileHandle.standardError.write((string + "\n").data(using: .utf8)!)
}

private func onQueue<T>(_ queue: Queue, _ f: () -> T) -> T {
    var result: T?
    queue.sync {
        result = f()
    }
    return result!
}

private func yuvaLength(width: Int, height: Int) -> Int {
    return width * height * 2 + ((width + 1) & ~1) * height / 2
}

// Premultiplied BGRA test pattern with soft alpha, like a rendered sticker.
private func makeArgbFrame(width: Int, height: Int, seed: Int) -> Data {
    var data = Data(count: width * 4 * height)
    data.withUnsafeMutableBytes { bytes in
        let pixels = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let dx = Double(x - width / 2), dy = Double(y - height / 2)
                let r = (dx * dx + dy * dy).squareRoot() / Double(width / 2)
                let alpha = UInt8(max(0.0, min(1.0, 1.2 - r)) * 255.0)
                let p = pixels.advanced(by: y * width * 4 + x * 4)
                p[0] = UInt8((Int(alpha) * ((x * 3 + seed) % 256)) / 255)
                p[1] = UInt8((Int(alpha) * ((y * 5 + seed) % 256)) / 255)
                p[2] = UInt8((Int(alpha) * ((x + y + seed * 7) % 256)) / 255)
                p[3] = alpha
            }
        }
    }
    return data
}

private func expectedYuva(argb: Data, width: Int, height: Int, unpremultiply: Bool) -> Data {
    var source = argb
    var result = Data(count: yuvaLength(width: width, height: height))
    source.withUnsafeMutableBytes { sourceBytes in
        result.withUnsafeMutableBytes { resultBytes in
            encodeRGBAToYUVA(resultBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), sourceBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(width), Int32(height), Int32(width * 4), true, unpremultiply)
        }
    }
    return result
}

private func waitUntil(timeout: Double = 10.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(10_000)
    }
    return condition()
}

private func readTableEntry(path: String, offset: Int) -> (Int, Int)? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= offset + 8 else {
        return nil
    }
    var frameOffset: Int32 = 0
    var frameLength: Int32 = 0
    _ = withUnsafeMutableBytes(of: &frameOffset) { data.copyBytes(to: $0, from: offset ..< offset + 4) }
    _ = withUnsafeMutableBytes(of: &frameLength) { data.copyBytes(to: $0, from: offset + 4 ..< offset + 8) }
    return (Int(frameOffset), Int(frameLength))
}

final class StickerFrameCacheTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        self.directory = NSTemporaryDirectory() + "sticker-frame-cache-tests-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    func testAnimatedStickerFramesRoundTripAsLZ4() throws {
        let queue = Queue()
        let width = 72, height = 72
        let prefix = self.directory + "/sticker"
        let frames = (0 ..< 3).map { makeArgbFrame(width: width, height: height, seed: $0 * 40) }

        var cacheValue: AnimatedStickerDirectFrameSourceCache? = onQueue(queue) { AnimatedStickerDirectFrameSourceCache(queue: queue, pathPrefix: prefix, width: width, height: height, frameCount: 3, fitzModifier: nil, useHardware: false) }
        var reopenedValue: AnimatedStickerDirectFrameSourceCache?
        defer {
            queue.sync {
                cacheValue = nil
                reopenedValue = nil
            }
        }
        let cache = try XCTUnwrap(cacheValue)
        XCTAssertTrue(cache.path.hasSuffix(".stickerframecachev4"))
        queue.sync {
            for (index, frame) in frames.enumerated() {
                cache.storeUncompressedRgbFrame(index: index, rgbData: frame)
            }
        }
        for (index, frame) in frames.enumerated() {
            var stored: AnimatedStickerFrame?
            XCTAssertTrue(waitUntil {
                stored = onQueue(queue) { cache.readCompressedFrame(index: index, totalFrames: 3) }
                return stored != nil
            })
            let expected = expectedYuva(argb: frame, width: width, height: height, unpremultiply: true)
            XCTAssertEqual(stored?.data, expected, "frame \(index)")
            XCTAssertEqual(stored?.type, .yuva)
        }

        // Stored frames are LZ4 blocks.
        let (offset, length) = try XCTUnwrap(readTableEntry(path: cache.path, offset: 0))
        let file = try Data(contentsOf: URL(fileURLWithPath: cache.path))
        XCTAssertGreaterThan(length, 4)
        XCTAssertEqual(file.subdata(in: offset ..< offset + 4), "bv41".data(using: .ascii))

        // A new instance reads the same frames back.
        reopenedValue = onQueue(queue) { AnimatedStickerDirectFrameSourceCache(queue: queue, pathPrefix: prefix, width: width, height: height, frameCount: 3, fitzModifier: nil, useHardware: false) }
        let again = onQueue(queue) { reopenedValue?.readCompressedFrame(index: 2, totalFrames: 3) }
        XCTAssertEqual(again?.data, expectedYuva(argb: frames[2], width: width, height: height, unpremultiply: true))
    }

    func testNewCacheFileRemovesThePreviousVersion() throws {
        let queue = Queue()
        let prefix = self.directory + "/sticker"
        let oldPath = AnimatedStickerDirectFrameSourceCache.path(pathPrefix: prefix, width: 72, height: 72, suffix: "", version: 3, useHardware: false)
        XCTAssertTrue(oldPath.hasSuffix("_72:72.stickerframecachev3"))
        try Data(count: 1000).write(to: URL(fileURLWithPath: oldPath))

        queue.sync {
            let cache = AnimatedStickerDirectFrameSourceCache(queue: queue, pathPrefix: prefix, width: 72, height: 72, frameCount: 10, fitzModifier: nil, useHardware: false)
            XCTAssertNotNil(cache)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))

        let videoOldPath = VideoStickerFrameSourceCache.path(pathPrefix: prefix, width: 72, height: 72, version: 3)
        XCTAssertTrue(videoOldPath.hasSuffix("_72x72-v3.vstickerframecache"))
        try Data(count: 1000).write(to: URL(fileURLWithPath: videoOldPath))
        queue.sync {
            let videoCache = VideoStickerFrameSourceCache(queue: queue, pathPrefix: prefix, width: 72, height: 72)
            XCTAssertNotNil(videoCache)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoOldPath))
    }

    func testDamagedFrameIsNotReturned() throws {
        let queue = Queue()
        let width = 72, height = 72
        let prefix = self.directory + "/sticker"
        var cacheValue: AnimatedStickerDirectFrameSourceCache? = onQueue(queue) { AnimatedStickerDirectFrameSourceCache(queue: queue, pathPrefix: prefix, width: width, height: height, frameCount: 1, fitzModifier: nil, useHardware: false) }
        var reopenedValue: AnimatedStickerDirectFrameSourceCache?
        defer {
            queue.sync {
                cacheValue = nil
                reopenedValue = nil
            }
        }
        let cache = try XCTUnwrap(cacheValue)
        queue.sync {
            cache.storeUncompressedRgbFrame(index: 0, rgbData: makeArgbFrame(width: width, height: height, seed: 1))
        }
        XCTAssertTrue(waitUntil { onQueue(queue) { cache.readCompressedFrame(index: 0, totalFrames: 1) } != nil })

        // Cut the frame short in the file: the reader returns nothing instead of a short frame.
        let (offset, length) = try XCTUnwrap(readTableEntry(path: cache.path, offset: 0))
        let handle = try XCTUnwrap(FileHandle(forUpdatingAtPath: cache.path))
        handle.truncateFile(atOffset: UInt64(offset + length / 2))
        handle.seek(toFileOffset: 4)
        var halfLength = Int32(length / 2)
        handle.write(Data(bytes: &halfLength, count: 4))
        handle.closeFile()

        reopenedValue = onQueue(queue) { AnimatedStickerDirectFrameSourceCache(queue: queue, pathPrefix: prefix, width: width, height: height, frameCount: 1, fitzModifier: nil, useHardware: false) }
        XCTAssertNotNil(reopenedValue)
        XCTAssertNil(onQueue(queue) { reopenedValue?.readCompressedFrame(index: 0, totalFrames: 1) })
    }

    func testVideoStickerFramesRoundTripAsLZ4() throws {
        let queue = Queue()
        let width = 64, height = 64
        let prefix = self.directory + "/video"
        let frames = (0 ..< 2).map { makeArgbFrame(width: width, height: height, seed: $0 * 90) }
        var cache: VideoStickerFrameSourceCache? = onQueue(queue) { VideoStickerFrameSourceCache(queue: queue, pathPrefix: prefix, width: width, height: height) }
        XCTAssertNotNil(cache)
        queue.sync {
            for (index, frame) in frames.enumerated() {
                cache?.storeUncompressedRgbFrame(index: index, rgbData: frame)
            }
        }
        // Frames are only readable once the count is known.
        queue.sync {
            cache?.storeFrameRateAndCount(frameRate: 30, frameCount: 2)
        }
        for (index, frame) in frames.enumerated() {
            var stored: Data?
            XCTAssertTrue(waitUntil {
                stored = onQueue(queue) { cache?.readUncompressedYuvaFrame(index: index) }
                return stored != nil
            })
            XCTAssertEqual(stored, expectedYuva(argb: frame, width: width, height: height, unpremultiply: false), "frame \(index)")
        }
        queue.sync {
            cache = nil
        }
    }

    // Real sticker frames from a format 3 (LZFSE) cache file, compressed both ways.
    func testBenchmarkFrameCompression() throws {
        let bundles = [Bundle(for: StickerFrameCacheTests.self), Bundle.main] + Bundle.allBundles
        guard let fixture = bundles.lazy.compactMap({ $0.path(forResource: "sticker72_v3", ofType: "bin") }).first else {
            throw XCTSkip("fixture missing")
        }
        let file = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let decodedLength = yuvaLength(width: 72, height: 72)
        var frames: [Data] = []
        var storedBytes = 0
        var index = 0
        while index * 8 + 8 <= file.count {
            guard let (offset, length) = readTableEntry(path: fixture, offset: index * 8) else {
                break
            }
            index += 1
            if length <= 0 || offset < index * 8 || offset + length > file.count {
                if offset == 0 && length == 0 && index > 1 {
                    continue
                }
                continue
            }
            let compressed = file.subdata(in: offset ..< offset + length)
            var output = Data(count: decodedLength)
            let result = output.withUnsafeMutableBytes { out in
                compressed.withUnsafeBytes { src in
                    compression_decode_buffer(out.baseAddress!.assumingMemoryBound(to: UInt8.self), decodedLength, src.baseAddress!.assumingMemoryBound(to: UInt8.self), length, nil, COMPRESSION_LZFSE)
                }
            }
            if result == decodedLength {
                frames.append(output)
                storedBytes += length
            }
        }
        XCTAssertGreaterThan(frames.count, 10)

        let iterations = 20
        for (name, algorithm) in [("LZFSE", COMPRESSION_LZFSE), ("LZ4", COMPRESSION_LZ4)] {
            var compressedFrames: [Data] = []
            let encodeStart = CFAbsoluteTimeGetCurrent()
            for i in 0 ..< iterations {
                for frame in frames {
                    let scratch = malloc(compression_encode_scratch_buffer_size(algorithm))!
                    var out = Data(count: frame.count)
                    let n = out.withUnsafeMutableBytes { o in frame.withUnsafeBytes { f in compression_encode_buffer(o.baseAddress!.assumingMemoryBound(to: UInt8.self), frame.count, f.baseAddress!.assumingMemoryBound(to: UInt8.self), frame.count, scratch, algorithm) } }
                    free(scratch)
                    out.count = n
                    if i == 0 {
                        compressedFrames.append(out)
                    }
                }
            }
            let encodeTime = (CFAbsoluteTimeGetCurrent() - encodeStart) / Double(iterations * frames.count)
            let bytes = compressedFrames.reduce(0) { $0 + $1.count }

            let scratch = malloc(max(1, compression_decode_scratch_buffer_size(algorithm)))!
            defer {
                free(scratch)
            }
            let decodeBuffer = malloc(decodedLength)!.assumingMemoryBound(to: UInt8.self)
            defer {
                free(decodeBuffer)
            }
            let decodeStart = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< iterations {
                for compressed in compressedFrames {
                    compressed.withUnsafeBytes { c in
                        if algorithm == COMPRESSION_LZFSE {
                            // The shipped path: decode into a scratch buffer, then copy into a new Data.
                            let n = compression_decode_buffer(decodeBuffer, decodedLength, c.baseAddress!.assumingMemoryBound(to: UInt8.self), c.count, scratch, algorithm)
                            let data = Data(bytes: decodeBuffer, count: n)
                            XCTAssertEqual(data.count, decodedLength)
                        } else {
                            let data = decompressFrame(bytes: c.baseAddress!.assumingMemoryBound(to: UInt8.self), length: c.count, decodedLength: decodedLength, scratch: scratch)
                            XCTAssertEqual(data?.count, decodedLength)
                        }
                    }
                }
            }
            let decodeTime = (CFAbsoluteTimeGetCurrent() - decodeStart) / Double(iterations * frames.count)
            log(String(format: "BENCH stickerframe %@ frames=%d encode=%.1fus/frame decode=%.1fus/frame bytes=%d (stored LZFSE %d)", name, frames.count, encodeTime * 1e6, decodeTime * 1e6, bytes, storedBytes))
        }
    }
}
