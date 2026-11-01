import Foundation
import XCTest
import AnimationCompression
import DctHuffman
@testable import AnimatedStickerNode

// The CPU half of the Metal sticker cache: the Huffman coder the DCT planes go through, and the
// checks a frame passes before it is coded or decoded. None of it needs a Metal device.
//
// Device crash (TestFlight 202611012130, GPU sticker renderer): EXC_BAD_ACCESS at
// 0xffffffff6dd50120 in writeDCTBlocks, from AnimationCompressor's command buffer completion
// handler. The faulting load was `codewords[diff]` with diff = INT_MIN: a plane read back from the
// GPU held a coefficient that was not finite or beyond Int32, which the coder turned into an index
// 8 GiB below its stack table. A DCT kernel that ran cannot produce one (|value| < 160); planes of a
// command buffer that did not complete, or that the next frame was writing, can.
final class DctCodecTests: XCTestCase {
    /// A plane of plausible coefficients: whole 8x8 blocks, DC and a few AC terms per block.
    private func plane(width: Int, height: Int, seed: Int) -> [Float] {
        var values = [Float](repeating: 0, count: width * height)
        var state = UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 1)
        func next() -> Float {
            state = state &* 1664525 &+ 1013904223
            return Float(Int(state >> 16) % 61) - 30.0
        }
        for blockY in stride(from: 0, to: height, by: 8) {
            for blockX in stride(from: 0, to: width, by: 8) {
                for i in 0 ..< 10 {
                    values[(blockY + i / 8) * width + blockX + i % 8] = i == 0 ? next() * 5.0 : next()
                }
            }
        }
        return values
    }

    private func encode(_ values: [Float], width: Int, height: Int) -> Data? {
        return values.withUnsafeBufferPointer { buffer -> Data? in
            guard let baseAddress = buffer.baseAddress else {
                return nil
            }
            return writeDCTBlocks(Int32(clamping: width), Int32(clamping: height), baseAddress)
        }
    }

    private func decode(_ data: Data, width: Int, height: Int, elementsPerRow: Int? = nil, into result: inout [Float]) {
        result.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            readDCTBlocks(Int32(clamping: width), Int32(clamping: height), data, baseAddress, Int32(clamping: elementsPerRow ?? width))
        }
    }

    private func decode(_ data: Data, width: Int, height: Int) -> [Float] {
        var result = [Float](repeating: .nan, count: width * height)
        self.decode(data, width: width, height: height, into: &result)
        return result
    }

    // The crash: such a plane must be refused, not coded.
    func testCoderRefusesCoefficientsTheKernelCannotProduce() {
        for value: Float in [-.infinity, .infinity, .nan, -3e9, 3e9, 5000, -40000, 2048, 1024] {
            for position in [0, 1, 63, 64 * 64 - 1] {
                var values = self.plane(width: 64, height: 64, seed: 1)
                values[position] = value
                XCTAssertNil(self.encode(values, width: 64, height: 64), "coefficient \(value) at \(position)")
            }
        }
        var values = self.plane(width: 64, height: 64, seed: 1)
        values[0] = 1023
        values[64] = -1023
        XCTAssertNotNil(self.encode(values, width: 64, height: 64), "the largest coded magnitude")
    }

    func testCoderRefusesPartialBlocks() {
        let values = [Float](repeating: 0, count: 64 * 64)
        for (width, height) in [(0, 8), (8, 0), (12, 8), (8, 20), (-8, 8)] {
            XCTAssertNil(self.encode(values, width: width, height: height), "\(width)x\(height)")
        }
    }

    // The coder is lossless: every block comes back, the last one included. The encoder used to
    // keep the last block's final bits and the decoder to stop one byte early; it then zeroed the
    // last block, which drew a half-transparent grey square in the corner of every cached frame.
    func testCoderRoundTripsEveryBlock() throws {
        for (width, height) in [(8, 8), (16, 16), (192, 192), (192, 80), (200, 200), (384, 384)] {
            for seed in 0 ..< 4 {
                let values = self.plane(width: width, height: height, seed: seed)
                let data = try XCTUnwrap(self.encode(values, width: width, height: height))
                XCTAssertEqual(self.decode(data, width: width, height: height), values, "\(width)x\(height), seed \(seed)")
            }
        }
    }

    func testDecoderLeavesRowPaddingAlone() throws {
        let width = 16
        let height = 16
        let elementsPerRow = 24
        let values = self.plane(width: width, height: height, seed: 7)
        let data = try XCTUnwrap(self.encode(values, width: width, height: height))
        var result = [Float](repeating: -1, count: elementsPerRow * height)
        self.decode(data, width: width, height: height, elementsPerRow: elementsPerRow, into: &result)
        for y in 0 ..< height {
            XCTAssertEqual(Array(result[y * elementsPerRow ..< y * elementsPerRow + width]), Array(values[y * width ..< (y + 1) * width]))
            XCTAssertEqual(Array(result[y * elementsPerRow + width ..< (y + 1) * elementsPerRow]), [Float](repeating: -1, count: elementsPerRow - width))
        }
    }

    // A size the decoder cannot write whole blocks of, or a destination narrower than the plane,
    // is ignored rather than written past.
    func testDecoderIgnoresSizesItCannotFill() throws {
        let data = try XCTUnwrap(self.encode(self.plane(width: 16, height: 16, seed: 3), width: 16, height: 16))
        var result = [Float](repeating: -1, count: 16 * 16)
        self.decode(data, width: 12, height: 16, elementsPerRow: 16, into: &result)
        self.decode(data, width: 16, height: 16, elementsPerRow: 8, into: &result)
        XCTAssertEqual(result, [Float](repeating: -1, count: 16 * 16))
    }

    func testDecoderSurvivesTruncatedAndGarbageData() throws {
        let width = 64
        let height = 64
        let data = try XCTUnwrap(self.encode(self.plane(width: width, height: height, seed: 5), width: width, height: height))
        for length in [0, 1, data.count / 2, data.count - 1] {
            _ = self.decode(data.prefix(length), width: width, height: height)
        }
        var state: UInt32 = 1
        let garbage = Data((0 ..< 4096).map { _ -> UInt8 in
            state = state &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: state >> 24)
        })
        _ = self.decode(garbage, width: width, height: height)
    }

    func testCompressibleSizes() {
        XCTAssertTrue(AnimationCompressor.canCompress(width: 384, height: 384))
        XCTAssertTrue(AnimationCompressor.canCompress(width: 384, height: 160))
        XCTAssertTrue(AnimationCompressor.canCompress(width: 16, height: 16))
        // Whole 8x8 luma blocks but half-size chroma planes of 4 pixels.
        XCTAssertFalse(AnimationCompressor.canCompress(width: 200, height: 200))
        XCTAssertFalse(AnimationCompressor.canCompress(width: 384, height: 72))
        XCTAssertFalse(AnimationCompressor.canCompress(width: 0, height: 16))
        XCTAssertFalse(AnimationCompressor.canCompress(width: 8192, height: 16))
    }

    // MARK: - The compressed frame format, as the renderer reads it from a cache file

    private func frame(width: Int, height: Int, mutate: (inout [Int32]) -> Void = { _ in }) throws -> Data {
        var header: [Int32] = [CompressedImageLayout.magic, 4, Int32(clamping: width), Int32(clamping: height)]
        var planeData: [Data] = []
        for size in CompressedImageLayout.planeSizes(width: width, height: height) {
            let data = try XCTUnwrap(self.encode(self.plane(width: size.width, height: size.height, seed: size.width), width: size.width, height: size.height))
            planeData.append(data)
            header.append(contentsOf: [Int32(clamping: size.width), Int32(clamping: size.height), Int32(clamping: size.width * 4), Int32(clamping: data.count)])
        }
        mutate(&header)
        var result = Data()
        func append(_ value: Int32) {
            var value = value
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        for i in 0 ..< 4 {
            append(header[i])
        }
        for plane in 0 ..< 4 {
            for i in 0 ..< 4 {
                append(header[4 + plane * 4 + i])
            }
            result.append(planeData[plane])
        }
        return result
    }

    func testLayoutAcceptsWhatTheCompressorWrites() throws {
        let data = try self.frame(width: 384, height: 160)
        let layout = try XCTUnwrap(CompressedImageLayout(data: data))
        XCTAssertEqual(layout.width, 384)
        XCTAssertEqual(layout.height, 160)
        XCTAssertEqual(layout.planes.map { $0.width }, [384, 192, 192, 384])
        XCTAssertEqual(layout.planes.map { $0.height }, [160, 80, 80, 160])
        // A slice of a larger buffer, as a frame read out of the cache file can be.
        let sliced = (Data([1, 2, 3]) + data).dropFirst(3)
        XCTAssertNotNil(CompressedImageLayout(data: sliced))
    }

    func testLayoutRefusesFramesThatDoNotMatchTheirTextures() throws {
        let mutations: [(String, (inout [Int32]) -> Void)] = [
            ("magic", { $0[0] = 0 }),
            ("plane count", { $0[1] = 3 }),
            ("width not whole 16-pixel blocks", { $0[2] = 200 }),
            ("negative height", { $0[3] = -160 }),
            ("luma plane wider than the frame", { $0[4] = 400 }),
            ("chroma plane at full size", { $0[8] = 384; $0[9] = 160 }),
            ("stride shorter than a row", { $0[6] = 384 }),
            ("negative plane length", { $0[7] = -1 }),
            ("plane length past the end", { $0[19] = 1 << 30 })
        ]
        for (name, mutation) in mutations {
            XCTAssertNil(CompressedImageLayout(data: try self.frame(width: 384, height: 160, mutate: mutation)), name)
        }
        let data = try self.frame(width: 384, height: 160)
        for length in [0, 3, 16, 20, data.count - 1] {
            XCTAssertNil(CompressedImageLayout(data: data.prefix(length)), "truncated to \(length)")
        }
    }

    // Frames written before the fix may hold planes read back from a failed or reused command
    // buffer; the Metal cache reads a new file name.
    func testMetalCacheUsesItsOwnVersionedFile() {
        let path = AnimatedStickerDirectFrameSourceCache.path(pathPrefix: "/tmp/x", width: 384, height: 384, suffix: "", version: AnimatedStickerDirectFrameSourceCache.version, useHardware: true)
        XCTAssertTrue(path.hasSuffix(".stickerframecachev4-mtl2"), path)
        let previous = AnimatedStickerDirectFrameSourceCache.path(pathPrefix: "/tmp/x", width: 384, height: 384, suffix: "", version: AnimatedStickerDirectFrameSourceCache.version, useHardware: true, metalVersion: 1)
        XCTAssertTrue(previous.hasSuffix(".stickerframecachev4-mtl"), previous)
        let software = AnimatedStickerDirectFrameSourceCache.path(pathPrefix: "/tmp/x", width: 384, height: 384, suffix: "", version: AnimatedStickerDirectFrameSourceCache.version, useHardware: false)
        XCTAssertTrue(software.hasSuffix(".stickerframecachev4"), software)
    }
}
