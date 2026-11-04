import XCTest
import CoreMedia
@testable import TelegramMediaPlayer

final class SoftwareVideoSkipLoopFilterTests: XCTestCase {
    private func readFrames(path: String, skipLoopFilter: Bool) -> [MediaTestSupport.DecodedFrame] {
        let source = SoftwareVideoSource(path: path, hintVP9: false, unpremultiplyAlpha: true, useHardwareAcceleration: false, skipLoopFilter: skipLoopFilter)
        var frames: [MediaTestSupport.DecodedFrame] = []
        for _ in 0 ..< 400 {
            let (frame, _, _, loop) = source.readFrame(maxPts: nil)
            if let frame = frame {
                frames.append(MediaTestSupport.frame(frame))
            }
            if loop {
                break
            }
        }
        return frames
    }

    func testSoftwareTilesSkipTheLoopFilter() throws {
        let path = try MediaTestSupport.resourcePath("h264_bframes", "mp4")
        let filtered = readFrames(path: path, skipLoopFilter: false)
        let skipped = readFrames(path: path, skipLoopFilter: true)
        XCTAssertGreaterThan(filtered.count, 10)
        XCTAssertEqual(skipped.count, filtered.count)
        XCTAssertEqual(skipped.map { $0.pts }, filtered.map { $0.pts })
        let differing = zip(skipped, filtered).filter { $0.bytes != $1.bytes }.count
        XCTAssertGreaterThan(differing, filtered.count / 2, "skip_loop_filter did not reach the decoder")
    }

    func testTheDefaultKeepsTheLoopFilter() throws {
        let path = try MediaTestSupport.resourcePath("h264_bframes", "mp4")
        let first = readFrames(path: path, skipLoopFilter: false)
        let second = SoftwareVideoSource(path: path, hintVP9: false, unpremultiplyAlpha: true)
        var frames: [MediaTestSupport.DecodedFrame] = []
        for _ in 0 ..< 400 {
            let (frame, _, _, loop) = second.readFrame(maxPts: nil)
            if let frame = frame {
                frames.append(MediaTestSupport.frame(frame))
            }
            if loop {
                break
            }
        }
        XCTAssertEqual(frames.count, first.count)
        XCTAssertTrue(zip(frames, first).allSatisfy { $0.bytes == $1.bytes })
    }

    func testGifTileOptions() {
        let budget = HardwareDecoderBudget(limit: 16)
        let small = GifTileHardwareDecoding.decoderOptions(width: 240, height: 240, hintVP9: false, budget: budget)
        XCTAssertNil(small.slot)
        XCTAssertTrue(small.skipLoopFilter)

        let large = GifTileHardwareDecoding.decoderOptions(width: 480, height: 270, hintVP9: false, budget: budget)
        XCTAssertNotNil(large.slot)
        XCTAssertFalse(large.skipLoopFilter)

        let vp9 = GifTileHardwareDecoding.decoderOptions(width: 480, height: 270, hintVP9: true, budget: budget)
        XCTAssertNil(vp9.slot)
        XCTAssertFalse(vp9.skipLoopFilter)

        let unknown = GifTileHardwareDecoding.decoderOptions(width: nil, height: nil, hintVP9: false, budget: budget)
        XCTAssertNil(unknown.slot)
        XCTAssertTrue(unknown.skipLoopFilter)

        var slots: [HardwareDecoderSlot] = []
        while let slot = HardwareDecoderSlot.acquire(from: budget) {
            slots.append(slot)
        }
        let overBudget = GifTileHardwareDecoding.decoderOptions(width: 640, height: 360, hintVP9: false, budget: budget)
        XCTAssertNil(overBudget.slot)
        XCTAssertTrue(overBudget.skipLoopFilter)
        withExtendedLifetime(slots) {}
        withExtendedLifetime(large) {}
    }
}
