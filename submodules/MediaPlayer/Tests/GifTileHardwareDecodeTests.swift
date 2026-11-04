import XCTest
import CoreMedia
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

// GIF tiles (BatchVideoRenderingContext) decode clips whose longer side is at least 320 px with the
// VideoToolbox hwaccel, smaller ones in software without the loop filter, and take at most
// `HardwareDecoderBudget`'s limit of hardware readers. The tiles detect a loop by the presentation
// time going backwards, so the hardware reader must give frames in presentation order, every loop.
final class GifTileHardwareDecodeTests: XCTestCase {
    private func makeTileReader(path: String, hardware: Bool, minimumLongSide: Int = 320) throws -> FFMpegFileReader {
        return try XCTUnwrap(FFMpegFileReader(
            source: .file(path),
            useHardwareAcceleration: hardware,
            hardwareAccelerationMinimumLongSide: minimumLongSide,
            skipLoopFilter: true,
            selectedStream: .mediaType(.video),
            seek: nil,
            maxReadablePts: nil
        ))
    }

    private func requireHardware(_ reader: FFMpegFileReader) throws {
        guard case let .frame(frame) = reader.readFrame(), let buffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
            throw XCTSkip("no frame")
        }
        if CVBufferCopyAttachment(buffer, "ColorInfoGuessedBy" as CFString, nil) == nil {
            throw XCTSkip("frames do not come from VideoToolbox here")
        }
    }

    func testSmallClipStaysInSoftware() throws {
        let path = try MediaTestSupport.makeClip(width: 240, height: 240, frameCount: 30, frameReordering: true, variableFrameDurations: false, color709: false)
        let reader = try makeTileReader(path: path, hardware: true)
        XCTAssertFalse(reader.isHardwareAccelerated)
        let software = MediaTestSupport.readFrames(try makeTileReader(path: path, hardware: false))
        XCTAssertTrue(MediaTestSupport.readFrames(reader) == software, "a small clip must decode exactly as before")
    }

    func testLargeClipUsesHardware() throws {
        for (width, height) in [(480, 270), (320, 180), (270, 480)] {
            let path = try MediaTestSupport.makeClip(width: width, height: height, frameCount: 30, frameReordering: true, variableFrameDurations: false, color709: false)
            let reader = try makeTileReader(path: path, hardware: true)
            XCTAssertTrue(reader.isHardwareAccelerated, "\(width)x\(height)")
            try requireHardware(try makeTileReader(path: path, hardware: true))
        }
    }

    // pts of every frame over several rewound loops: within a loop strictly increasing and equal to
    // the software reader's, so `TargetState.render` sees a backwards step only at the loop point.
    func testHardwareLoopsKeepPresentationOrder() throws {
        let generated = try MediaTestSupport.makeClip(width: 480, height: 270, frameCount: 45, frameReordering: true, variableFrameDurations: false, color709: false)
        var paths = [generated]
        if let fixture = try? MediaTestSupport.resourcePath("h264_bframes", "mp4") {
            paths.append(fixture)
        }
        for path in paths {
            let softwarePts = MediaTestSupport.readFrames(try makeTileReader(path: path, hardware: false)).map(\.pts)
            XCTAssertGreaterThan(softwarePts.count, 10)
            // The 256x144 fixture is below the tile threshold; decode it in hardware anyway.
            let reader = try makeTileReader(path: path, hardware: true, minimumLongSide: 0)
            XCTAssertTrue(reader.isHardwareAccelerated)
            for loop in 0 ..< 3 {
                if loop > 0 {
                    XCTAssertTrue(reader.rewind())
                }
                let pts = MediaTestSupport.readFrames(reader).map(\.pts)
                XCTAssertEqual(pts, softwarePts, "loop \(loop)")
                for i in 1 ..< pts.count {
                    XCTAssertGreaterThan(pts[i], pts[i - 1], "loop \(loop) frame \(i)")
                }
            }
        }
    }

    func testBudgetCapsLiveReaders() {
        let budget = HardwareDecoderBudget(limit: 2)
        XCTAssertTrue(budget.tryAcquire())
        XCTAssertTrue(budget.tryAcquire())
        XCTAssertFalse(budget.tryAcquire())
        XCTAssertEqual(budget.activeCount, 2)
        budget.release()
        XCTAssertTrue(budget.tryAcquire())
        budget.release()
        budget.release()
        XCTAssertEqual(budget.activeCount, 0)
    }
}

final class GifTileHardwareDecodingPolicyTests: XCTestCase {
    func testSmallClipsStayInSoftware() {
        XCTAssertFalse(GifTileHardwareDecoding.wantsHardware(width: 240, height: 240))
        XCTAssertFalse(GifTileHardwareDecoding.wantsHardware(width: 256, height: 144))
        XCTAssertNil(GifTileHardwareDecoding.acquireSlot(width: 240, height: 240, budget: HardwareDecoderBudget(limit: 16)))
    }

    func testClipsFrom320PixelsAskForHardware() {
        for (width, height) in [(480, 270), (320, 180), (270, 480), (320, 320)] {
            XCTAssertTrue(GifTileHardwareDecoding.wantsHardware(width: width, height: height), "\(width)x\(height)")
        }
    }

    func testBudgetCapsLiveHardwareReaders() {
        let budget = HardwareDecoderBudget(limit: 16)
        var slots: [HardwareDecoderSlot] = []
        for _ in 0 ..< 20 {
            if let slot = GifTileHardwareDecoding.acquireSlot(width: 480, height: 360, budget: budget) {
                slots.append(slot)
            }
        }
        XCTAssertEqual(slots.count, 16)
        XCTAssertEqual(budget.activeCount, 16)
        XCTAssertNil(GifTileHardwareDecoding.acquireSlot(width: 480, height: 360, budget: budget))
        slots.removeFirst(4)
        XCTAssertEqual(budget.activeCount, 12)
        XCTAssertNotNil(GifTileHardwareDecoding.acquireSlot(width: 480, height: 360, budget: budget))
        XCTAssertEqual(budget.activeCount, 12)
        slots.removeAll()
        XCTAssertEqual(budget.activeCount, 0)
    }

    func testSharedBudgetIsSixteen() {
        let before = GifTileHardwareDecoding.budget.activeCount
        var slots: [HardwareDecoderSlot] = []
        while let slot = GifTileHardwareDecoding.acquireSlot(width: 640, height: 360) {
            slots.append(slot)
            if slots.count > 32 {
                break
            }
        }
        XCTAssertEqual(slots.count + before, 16)
    }
}
