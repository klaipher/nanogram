import XCTest
import AVFoundation
@testable import OpusKit

/// WATCH-MEM-1: the chunked decoder must produce exactly the samples of the whole-file decode, in bounded pieces.
final class OpusChunkedDecoderTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "voice_note", withExtension: "ogg") else {
            throw XCTSkip("fixture not bundled: voice_note.ogg")
        }
        return url
    }

    /// Mono Ogg Opus made with this package's own encoder and writer (no fixture needed): `seconds` of a sine.
    private func makeSyntheticFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(UUID().uuidString).ogg")
        let writer = try OggOpusWriter(url: url)
        let encoder = try OpusEncoder()
        let frames = Int(seconds * 50)
        for n in 0..<frames {
            var frame = [Float](repeating: 0, count: OpusEncoder.frameSize)
            for i in 0..<OpusEncoder.frameSize {
                frame[i] = 0.4 * sinf(Float(n * OpusEncoder.frameSize + i) * 0.05)
            }
            writer.writePacket(try encoder.encode(frame), samples: OpusEncoder.frameSize)
        }
        writer.finish()
        return url
    }

    private func collect(_ decoder: OpusChunkedDecoder, maxFrames: Int) throws -> (left: [Float], right: [Float], chunks: [Int]) {
        var left: [Float] = []
        var right: [Float] = []
        var chunks: [Int] = []
        while let chunk = try decoder.nextChunk(maxFrames: maxFrames) {
            let n = Int(chunk.frameLength)
            chunks.append(n)
            let data = try XCTUnwrap(chunk.floatChannelData)
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            if chunk.format.channelCount == 2 {
                right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: n))
            }
        }
        return (left, right, chunks)
    }

    private func assertMatchesFullDecode(_ url: URL, maxFrames: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let full = try OpusDecoder.decodePCM(url: url).pcm
        let decoder = try OpusChunkedDecoder(url: url)
        XCTAssertEqual(decoder.channelCount, Int(full.format.channelCount), file: file, line: line)
        let out = try collect(decoder, maxFrames: maxFrames)
        XCTAssertEqual(out.left.count, Int(full.frameLength), "total frames (pre-skip applied)", file: file, line: line)
        let data = try XCTUnwrap(full.floatChannelData)
        let reference = Array(UnsafeBufferPointer(start: data[0], count: Int(full.frameLength)))
        XCTAssertEqual(out.left, reference, "left channel is sample-exact", file: file, line: line)
        if full.format.channelCount == 2 {
            let ref1 = Array(UnsafeBufferPointer(start: data[1], count: Int(full.frameLength)))
            XCTAssertEqual(out.right, ref1, "right channel is sample-exact", file: file, line: line)
        }
        let bound = maxFrames + OpusChunkedDecoder.maxFramesPerPacket
        XCTAssertTrue(out.chunks.allSatisfy { $0 > 0 && $0 <= bound }, "chunk sizes \(out.chunks.prefix(5))", file: file, line: line)
    }

    func testChunksReassembleToTheFullDecodeOfTheFixture() throws {
        let url = try fixtureURL()
        try assertMatchesFullDecode(url, maxFrames: 4_800)
        try assertMatchesFullDecode(url, maxFrames: 24_000)
    }

    func testChunksReassembleToTheFullDecodeOfASyntheticNote() throws {
        let url = try makeSyntheticFile(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertMatchesFullDecode(url, maxFrames: 1)       // one packet per chunk
        try assertMatchesFullDecode(url, maxFrames: 7_000)
        try assertMatchesFullDecode(url, maxFrames: 1_000_000) // a single chunk
    }

    func testPreSkipIsTrimmedFromTheFirstChunk() throws {
        let url = try makeSyntheticFile(seconds: 1)   // 50 packets of 960 frames, pre-skip 312
        defer { try? FileManager.default.removeItem(at: url) }
        let out = try collect(try OpusChunkedDecoder(url: url), maxFrames: 1_000_000)
        XCTAssertEqual(out.left.count, 50 * 960 - 312)
    }

    func testTotalDurationFollowsTheGranulePosition() throws {
        let url = try makeSyntheticFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try OpusChunkedDecoder(url: url)
        let duration = try XCTUnwrap(decoder.totalDuration)
        XCTAssertEqual(duration, (100.0 * 960 - 312) / 48_000, accuracy: 0.001)
    }

    func testReturnsNilAfterTheEndAndKeepsReturningNil() throws {
        let url = try makeSyntheticFile(seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try OpusChunkedDecoder(url: url)
        while try decoder.nextChunk(maxFrames: 4_800) != nil {}
        XCTAssertNil(try decoder.nextChunk(maxFrames: 4_800))
        XCTAssertNil(try decoder.nextChunk(maxFrames: 4_800))
    }

    func testRejectsMissingAndNonOggFiles() throws {
        XCTAssertThrowsError(try OpusChunkedDecoder(url: URL(fileURLWithPath: "/nonexistent/voice.ogg"))) { error in
            guard case OpusDecoderError.fileNotFound = error else { return XCTFail("\(error)") }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-not-ogg-\(UUID().uuidString).bin")
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try OpusChunkedDecoder(url: tmp)) { error in
            guard case OpusDecoderError.notOggOpus = error else { return XCTFail("\(error)") }
        }
    }

    func testRejectsAnOggFileThatIsNotOpus() throws {
        // "OggS" magic but no valid page after it.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-bad-\(UUID().uuidString).ogg")
        try Data([0x4F, 0x67, 0x67, 0x53, 0, 0, 0, 0, 0, 0]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try OpusChunkedDecoder(url: tmp))
    }
}
