import Foundation
import XCTest
import Compression
import SwiftSignalKit
import AnimationCache
@testable import DCTAnimationCacheImpl

private typealias Support = DCTAnimationCacheTestSupport

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    var value: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset ..< offset + 4) }
    return value
}

// Format 8 compresses the frame stream in blocks of about 64 KB with LZBITMAP instead of one LZFSE
// stream. A block holds whole frames only, and the header names the codec (LZMESH files, which no
// build writes by default, are read on iOS 27+). Formats 6 and 7 stay readable.
final class DCTAnimationCacheFormat8Tests: XCTestCase {
    private var basePath: String!

    override func setUp() {
        super.setUp()
        self.basePath = Support.makeTempDirectory()
    }

    override func tearDown() {
        dctAnimationCacheWriterCodecOverride = nil
        try? FileManager.default.removeItem(atPath: self.basePath)
        try? FileManager.default.removeItem(atPath: self.basePath + "-temp")
        super.tearDown()
    }

    // The same goldens as DCTAnimationCacheFormatTests: format 8 carries the same coefficients.
    private static let reencodeGoldens: [(name: String, width: Int, height: Int, checksum: UInt64)] = [
        ("emoji62_v6", 62, 62, 15546205421717925383),
        ("sticker160_v6", 160, 160, 9107420832002127963),
    ]

    private func fixtureFrames(_ cache: AnimationCache, base: String, name: String, width: Int, height: Int) throws -> [(data: Data, width: Int, height: Int, bytesPerRow: Int, duration: Double)] {
        let sourceId = "fixture-\(name)"
        _ = try Support.installFixture(name, basePath: base, sourceId: sourceId, width: width, height: height)
        let item = try XCTUnwrap(Support.getItem(cache: cache, sourceId: sourceId, width: width, height: height, fetch: Support.failingFetch))
        return Support.decodeFrames(item)
    }

    func testNewItemsAreWrittenInFormat8WithLZBITMAP() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        let frames = try self.fixtureFrames(cache, base: self.basePath, name: "emoji62_v6", width: 62, height: 62)
        XCTAssertNotNil(Support.writeFrames(cache: cache, sourceId: "new", width: 62, height: 62, frames: frames))
        let path = Support.itemPath(basePath: self.basePath, sourceId: "new", width: 62, height: 62)
        XCTAssertEqual(Support.storedFormatVersion(path: path), 8)
        XCTAssertEqual(Support.storedFormatVersion(path: path + "-f"), 8)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(data[4], DCTAnimationCacheCodec.lzbitmap.rawValue)
    }

    func testFormat8DecodesToRecordedPixelsWithEitherCodec() throws {
        for codec in [DCTAnimationCacheCodec.lzbitmap, .lzmesh] {
            if codec == .lzmesh, #unavailable(iOS 27.0) {
                continue
            }
            dctAnimationCacheWriterCodecOverride = codec
            let base = self.basePath + "/\(codec)"
            let cache = Support.makeCache(basePath: base)
            for golden in Self.reencodeGoldens {
                let frames = try self.fixtureFrames(cache, base: base, name: golden.name, width: golden.width, height: golden.height)
                let reencodedId = "reencoded-\(golden.name)"
                let reencoded = try XCTUnwrap(Support.writeFrames(cache: cache, sourceId: reencodedId, width: golden.width, height: golden.height, frames: frames))
                let path = Support.itemPath(basePath: base, sourceId: reencodedId, width: golden.width, height: golden.height)
                XCTAssertEqual(Support.storedFormatVersion(path: path), 8)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path))[4], codec.rawValue)
                let checksum = Support.checksum(frames: Support.decodeFrames(reencoded))
                XCTAssertEqual(checksum, golden.checksum, "\(golden.name) \(codec)")
                // Looping decodes the same frames again.
                XCTAssertEqual(Support.checksum(frames: Support.decodeFrames(reencoded)), checksum, "\(golden.name) \(codec) second loop")
                let fresh = try XCTUnwrap(Support.getItem(cache: cache, sourceId: reencodedId, width: golden.width, height: golden.height, fetch: Support.failingFetch))
                XCTAssertEqual(Support.checksum(frames: Support.decodeFrames(fresh)), checksum, golden.name)
            }
        }
    }

    // Walks the blocks of a format 8 file and checks that each one decodes to whole frames.
    func testBlocksHoldWholeFramesOfAbout64KB() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        let frames = try self.fixtureFrames(cache, base: self.basePath, name: "sticker160_v6", width: 160, height: 160)
        XCTAssertNotNil(Support.writeFrames(cache: cache, sourceId: "blocks", width: 160, height: 160, frames: frames))
        let data = try Data(contentsOf: URL(fileURLWithPath: Support.itemPath(basePath: self.basePath, sourceId: "blocks", width: 160, height: 160)))
        let codec = try XCTUnwrap(DCTAnimationCacheCodec(rawValue: data[4]))

        var offset = 4 + 1 + 8
        for _ in 0 ..< 3 {
            offset += 4 + Int(readUInt32(data, offset))
        }
        let contentLength = Int(readUInt32(data, offset))
        offset += 4
        let contentEnd = offset + contentLength
        let frameCount = Int(readUInt32(data, contentEnd))
        XCTAssertEqual(frameCount, 30)

        var blockCount = 0
        var parsedFrames = 0
        while offset < contentEnd {
            let rawLength = Int(readUInt32(data, offset))
            let compressedLength = Int(readUInt32(data, offset + 4))
            offset += 8
            XCTAssertLessThanOrEqual(offset + compressedLength, contentEnd)
            var raw = Data(count: rawLength)
            let decoded = raw.withUnsafeMutableBytes { rawBytes in
                data.withUnsafeBytes { bytes in
                    compression_decode_buffer(rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), rawLength, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), compressedLength, nil, codec.algorithm)
                }
            }
            XCTAssertEqual(decoded, rawLength)
            offset += compressedLength
            blockCount += 1

            // Frame: length, type, then per plane: size, encoded length, encoded bytes.
            var position = 0
            var framesInBlock = 0
            while position < rawLength {
                position += 8
                for _ in 0 ..< 4 {
                    position += 4
                    position += 4 + Int(readUInt32(raw, position))
                }
                framesInBlock += 1
            }
            XCTAssertEqual(position, rawLength, "block \(blockCount) ends inside a frame")
            XCTAssertGreaterThan(framesInBlock, 0)
            parsedFrames += framesInBlock
            if offset < contentEnd {
                // Only the last block may be short.
                XCTAssertGreaterThanOrEqual(rawLength, 64 * 1024, "block \(blockCount)")
            }
        }
        XCTAssertEqual(offset, contentEnd)
        XCTAssertEqual(parsedFrames, 30)
        XCTAssertGreaterThan(blockCount, 1)
    }

    // A file whose codec this OS cannot decode, or whose codec byte is unknown, is converted again.
    func testUnknownCodecIsRejected() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        let frames = try self.fixtureFrames(cache, base: self.basePath, name: "emoji62_v6", width: 62, height: 62)
        XCTAssertNotNil(Support.writeFrames(cache: cache, sourceId: "codec", width: 62, height: 62, frames: frames))
        let path = Support.itemPath(basePath: self.basePath, sourceId: "codec", width: 62, height: 62)
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        data[4] = 0x7f
        try data.write(to: URL(fileURLWithPath: path))
        var fetched = false
        _ = Support.getItem(cache: cache, sourceId: "codec", width: 62, height: 62, timeout: 2.0, fetch: { options in
            fetched = true
            options.writer.finish()
            return EmptyDisposable
        })
        XCTAssertTrue(fetched)
    }
}
