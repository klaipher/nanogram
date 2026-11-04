import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

// GIF tiles (GIF panel, inline results, shared media) read through GifTileVideoSource. Our FFmpeg
// has no MPEG-4 Part 2 decoder, so such GIFs used to get no stream at all and kept their
// thumbnail; they are now read in passthrough and the tile's sample buffer layer decodes them.
// Software-decoded tiles draw their pixel buffers from a pool. Port of iOS 3847647f and the tile
// half of 4cc94ee2.
final class GifTileVideoSourceTests: XCTestCase {
    private struct ReadFrame {
        let frame: MediaTrackFrame
        let bytes: Data
    }

    private func mpeg4Path() throws -> String {
        return try MediaTestSupport.resourcePath("mpeg4_part2", "mp4")
    }

    // Reads one loop of the clip the way SoftwareVideoLayerFrameManager does.
    private func readLoop(_ source: SoftwareVideoSource, maxPts: CMTime?, consume: (MediaTrackFrame) -> Void = { _ in }) -> [ReadFrame] {
        var frames: [ReadFrame] = []
        for _ in 0 ..< 400 {
            let (frame, _, _, loop) = source.readFrame(maxPts: maxPts)
            if let frame {
                consume(frame)
                frames.append(ReadFrame(frame: frame, bytes: MediaTestSupport.frame(frame).bytes))
            }
            if loop {
                break
            }
        }
        return frames
    }

    private func attachment(_ sampleBuffer: CMSampleBuffer, _ key: CFString) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]], let first = attachments.first else {
            return false
        }
        return (first[key] as? Bool) == true
    }

    func testFFmpegCannotDecodeMpeg4Part2() throws {
        let source = SoftwareVideoSource(path: try mpeg4Path(), hintVP9: false, unpremultiplyAlpha: true)
        XCTAssertFalse(source.hasStream)
    }

    func testMpeg4Part2ClipOpensInPassthroughAndGivesBackTheHardwareSlot() throws {
        let budget = HardwareDecoderBudget(limit: 16)
        let tile = GifTileVideoSource(path: try mpeg4Path(), hintVP9: false, width: 360, height: 360, usesHardwareDecoding: true, budget: budget)
        XCTAssertTrue(tile.source.hasStream)
        XCTAssertTrue(tile.isPassthrough)
        XCTAssertNil(tile.hardwareSlot)
        XCTAssertEqual(budget.activeCount, 0)

        let frames = readLoop(tile.source, maxPts: nil)
        XCTAssertGreaterThan(frames.count, 10)
        for (index, read) in frames.enumerated() {
            XCTAssertFalse(read.frame.decoded)
            XCTAssertNil(CMSampleBufferGetImageBuffer(read.frame.sampleBuffer))
            XCTAssertFalse(read.bytes.isEmpty)
            XCTAssertTrue(attachment(read.frame.sampleBuffer, kCMSampleAttachmentKey_DisplayImmediately), "frame \(index)")
        }
        XCTAssertTrue(attachment(try XCTUnwrap(frames.first).frame.sampleBuffer, kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding))
    }

    func testVideoToolboxDecodesEveryPassthroughFrame() throws {
        let tile = GifTileVideoSource(path: try mpeg4Path(), hintVP9: false, width: 360, height: 360, usesHardwareDecoding: true, budget: HardwareDecoderBudget(limit: 16))
        let frames = readLoop(tile.source, maxPts: nil)
        XCTAssertGreaterThan(frames.count, 10)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(try XCTUnwrap(frames.first).frame.sampleBuffer))

        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session), noErr)
        let decoder = try XCTUnwrap(session)
        defer {
            VTDecompressionSessionInvalidate(decoder)
        }
        var decodedCount = 0
        for (index, read) in frames.enumerated() {
            var outputStatus: OSStatus = -1
            var image: CVImageBuffer?
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: read.frame.sampleBuffer, flags: [], infoFlagsOut: nil, outputHandler: { status, _, imageBuffer, _, _ in
                outputStatus = status
                image = imageBuffer
            })
            XCTAssertEqual(status, noErr, "frame \(index)")
            XCTAssertEqual(outputStatus, noErr, "frame \(index)")
            if image != nil {
                decodedCount += 1
            }
        }
        XCTAssertEqual(decodedCount, frames.count)
    }

    func testPassthroughLoopRepeatsFramesAfterTheFirstLoop() throws {
        let tile = GifTileVideoSource(path: try mpeg4Path(), hintVP9: false, width: 360, height: 360, usesHardwareDecoding: false)
        let first = readLoop(tile.source, maxPts: nil)
        XCTAssertGreaterThan(first.count, 10)
        let last = try XCTUnwrap(first.last)
        let offset = CMTimeAdd(last.frame.position, last.frame.duration)

        let second = readLoop(tile.source, maxPts: offset)
        XCTAssertEqual(second.count, first.count)
        XCTAssertEqual(second.map { $0.bytes }, first.map { $0.bytes })
        for (lhs, rhs) in zip(first, second) {
            XCTAssertEqual(CMTimeCompare(rhs.frame.position, CMTimeAdd(lhs.frame.position, offset)), 0)
        }
        XCTAssertTrue(attachment(try XCTUnwrap(second.first).frame.sampleBuffer, kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding))
    }

    func testH264StillDecodesWithFFmpeg() throws {
        let tile = GifTileVideoSource(path: try MediaTestSupport.resourcePath("h264_bframes", "mp4"), hintVP9: false, width: 240, height: 240, usesHardwareDecoding: true, budget: HardwareDecoderBudget(limit: 16))
        XCTAssertTrue(tile.source.hasStream)
        XCTAssertFalse(tile.isPassthrough)
        let frames = readLoop(tile.source, maxPts: nil)
        XCTAssertGreaterThan(frames.count, 10)
        XCTAssertTrue(frames.allSatisfy { $0.frame.decoded && CMSampleBufferGetImageBuffer($0.frame.sampleBuffer) != nil })
    }

    func testUnreadableFileHasNoStream() throws {
        let path = MediaTestSupport.tempDirectory + "/not-a-video.mp4"
        try Data(repeating: 0x5a, count: 4096).write(to: URL(fileURLWithPath: path))
        let budget = HardwareDecoderBudget(limit: 16)
        let tile = GifTileVideoSource(path: path, hintVP9: false, width: 480, height: 480, usesHardwareDecoding: true, budget: budget)
        XCTAssertFalse(tile.source.hasStream)
        XCTAssertNil(tile.hardwareSlot)
        XCTAssertEqual(budget.activeCount, 0)
    }

    // MARK: Pixel buffer reuse for software-decoded tiles

    private func softwareTile(_ path: String) -> GifTileVideoSource {
        return GifTileVideoSource(path: path, hintVP9: false, width: 240, height: 240, usesHardwareDecoding: false)
    }

    func testSoftwareTileFramesMatchFramesWithoutReuse() throws {
        let path = try MediaTestSupport.resourcePath("h264_bframes", "mp4")
        let reference = readLoop(SoftwareVideoSource(path: path, hintVP9: false, unpremultiplyAlpha: true, reusePixelBuffers: false), maxPts: nil).map { $0.bytes }
        XCTAssertGreaterThan(reference.count, 10)

        let tile = softwareTile(path)
        XCTAssertTrue(tile.source.reusesPixelBuffers)
        XCTAssertEqual(readLoop(tile.source, maxPts: nil).map { $0.bytes }, reference)
    }

    func testSoftwareTileHeldFramesAreNotOverwritten() throws {
        let path = try MediaTestSupport.resourcePath("h264_bframes", "mp4")
        let reference = readLoop(SoftwareVideoSource(path: path, hintVP9: false, unpremultiplyAlpha: true, reusePixelBuffers: false), maxPts: nil).map { $0.bytes }

        var held: [CMSampleBuffer] = []
        let _ = readLoop(softwareTile(path).source, maxPts: nil, consume: { held.append($0.sampleBuffer) })
        XCTAssertEqual(held.count, reference.count)
        XCTAssertEqual(Set(held.map { ObjectIdentifier(CMSampleBufferGetImageBuffer($0)!) }).count, held.count)
        for (index, sampleBuffer) in held.enumerated() where index < reference.count {
            XCTAssertEqual(MediaTestSupport.visibleBytes(CMSampleBufferGetImageBuffer(sampleBuffer)!), reference[index], "held frame \(index) was overwritten")
        }
    }

    // MARK: Video stickers (VP9 with alpha) on the tile path

    // Video stickers in chat, and GIFs in the gallery and hover preview, also read through
    // GifTileVideoSource, so their ARGB frames now come from the reused pool as well.
    private func stickerPath() throws -> String {
        return try MediaTestSupport.resourcePath("sticker_vp9", "webm")
    }

    private func stickerTile() throws -> GifTileVideoSource {
        return GifTileVideoSource(path: try stickerPath(), hintVP9: true, width: 512, height: 512, usesHardwareDecoding: true, budget: HardwareDecoderBudget(limit: 16))
    }

    private func stickerReference() throws -> [Data] {
        let source = SoftwareVideoSource(path: try stickerPath(), hintVP9: true, unpremultiplyAlpha: true, reusePixelBuffers: false)
        XCTAssertFalse(source.reusesPixelBuffers)
        return readLoop(source, maxPts: nil).map { $0.bytes }
    }

    private func alphaRange(_ pixelBuffer: CVPixelBuffer) -> (min: UInt8, max: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            return (0, 0)
        }
        var minAlpha: UInt8 = 255
        var maxAlpha: UInt8 = 0
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0 ..< CVPixelBufferGetHeight(pixelBuffer) {
            for x in 0 ..< CVPixelBufferGetWidth(pixelBuffer) {
                let alpha = base[y * bytesPerRow + x * 4]
                minAlpha = min(minAlpha, alpha)
                maxAlpha = max(maxAlpha, alpha)
            }
        }
        return (minAlpha, maxAlpha)
    }

    func testVideoStickerTileDecodesTransparentARGBFromThePool() throws {
        let budget = HardwareDecoderBudget(limit: 16)
        let tile = GifTileVideoSource(path: try stickerPath(), hintVP9: true, width: 512, height: 512, usesHardwareDecoding: true, budget: budget)
        XCTAssertTrue(tile.source.hasStream)
        XCTAssertFalse(tile.isPassthrough)
        XCTAssertNil(tile.hardwareSlot)
        XCTAssertEqual(budget.activeCount, 0)
        XCTAssertTrue(tile.source.reusesPixelBuffers)

        var held: [CVPixelBuffer] = []
        let frames = readLoop(tile.source, maxPts: nil, consume: { held.append(CMSampleBufferGetImageBuffer($0.sampleBuffer)!) })
        XCTAssertGreaterThan(frames.count, 10)
        XCTAssertTrue(frames.allSatisfy { $0.frame.decoded })
        for (index, pixelBuffer) in held.enumerated() {
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixelBuffer), kCVPixelFormatType_32ARGB, "frame \(index)")
            let alpha = alphaRange(pixelBuffer)
            XCTAssertEqual(alpha.min, 0, "frame \(index) lost its transparent edges")
            XCTAssertEqual(alpha.max, 255, "frame \(index)")
        }
    }

    func testVideoStickerTileFramesMatchFramesWithoutReuse() throws {
        let reference = try stickerReference()
        XCTAssertGreaterThan(reference.count, 10)
        XCTAssertEqual(readLoop(try stickerTile().source, maxPts: nil).map { $0.bytes }, reference)
    }

    func testVideoStickerTileHeldFramesAreNotOverwrittenAcrossLoops() throws {
        let reference = try stickerReference()
        XCTAssertGreaterThan(reference.count, 10)

        let tile = try stickerTile()
        var held: [CMSampleBuffer] = []
        let first = readLoop(tile.source, maxPts: nil, consume: { held.append($0.sampleBuffer) })
        let last = try XCTUnwrap(first.last)
        let _ = readLoop(tile.source, maxPts: CMTimeAdd(last.frame.position, last.frame.duration), consume: { held.append($0.sampleBuffer) })
        XCTAssertEqual(held.count, reference.count * 2)
        XCTAssertEqual(Set(held.map { ObjectIdentifier(CMSampleBufferGetImageBuffer($0)!) }).count, held.count)
        for (index, sampleBuffer) in held.enumerated() {
            XCTAssertEqual(MediaTestSupport.visibleBytes(CMSampleBufferGetImageBuffer(sampleBuffer)!), reference[index % reference.count], "held frame \(index) was overwritten")
        }
    }

    // MARK: Which due frames a tile enqueues

    private func frames(decoded: Bool, count: Int) throws -> [MediaTrackFrame] {
        var result: [MediaTrackFrame] = []
        for index in 0 ..< count {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 10), decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer), noErr)
            result.append(MediaTrackFrame(type: .video, sampleBuffer: try XCTUnwrap(sampleBuffer), resetDecoder: false, decoded: decoded))
        }
        return result
    }

    func testDecodedFramesSkipToTheLatestDueFrame() throws {
        let frames = try frames(decoded: true, count: 5)
        let result = GifTileFrameSchedule.framesToEnqueue(frames, baseTimestamp: 100.0, timestamp: 100.35)
        XCTAssertEqual(result.consumedCount, 3)
        XCTAssertEqual(result.enqueue.map { ObjectIdentifier($0) }, [ObjectIdentifier(frames[2])])
    }

    func testCompressedFramesAreAllEnqueuedInOrder() throws {
        let frames = try frames(decoded: false, count: 5)
        let result = GifTileFrameSchedule.framesToEnqueue(frames, baseTimestamp: 100.0, timestamp: 100.35)
        XCTAssertEqual(result.consumedCount, 3)
        XCTAssertEqual(result.enqueue.map { ObjectIdentifier($0) }, frames[0 ..< 3].map { ObjectIdentifier($0) })
    }

    func testNothingIsDueBeforeTheFirstFrameEnds() throws {
        let frames = try frames(decoded: false, count: 3)
        let result = GifTileFrameSchedule.framesToEnqueue(frames, baseTimestamp: 100.0, timestamp: 100.05)
        XCTAssertEqual(result.consumedCount, 0)
        XCTAssertTrue(result.enqueue.isEmpty)
    }
}
