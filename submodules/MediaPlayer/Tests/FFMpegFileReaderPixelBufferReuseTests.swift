import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface
@testable import TelegramMediaPlayer

// FFMpegFileReader (GIF grid, video stickers, frame previews, software HLS) used to create a new
// IOSurface-backed CVPixelBuffer and a new CMVideoFormatDescription for every decoded frame. It now
// draws buffers from a CVPixelBufferPool and keeps the format description while it still matches.
// These tests pin that the frames are byte-identical either way, that a frame somebody still holds
// is never overwritten by a later one, and that the pool and the description are actually reused.
final class FFMpegFileReaderPixelBufferReuseTests: XCTestCase {
    private static var tempDirectory: String = {
        let path = NSTemporaryDirectory() + "FFMpegFileReaderPixelBufferReuseTests"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    private static var h264Path: String?

    // MARK: Fixtures

    private func stickerPath() throws -> String {
        let bundles = [Bundle.module, Bundle(for: FFMpegFileReaderPixelBufferReuseTests.self), Bundle.main] + Bundle.allBundles
        for bundle in bundles {
            if let path = bundle.path(forResource: "sticker_vp9", ofType: "webm") {
                return path
            }
        }
        throw XCTSkip("sticker_vp9.webm is not in the test bundle")
    }

    // A deterministic 4:2:0 H.264 clip, the shape GIFs in the GIF grid have.
    private func makeH264Clip() throws -> String {
        if let path = FFMpegFileReaderPixelBufferReuseTests.h264Path {
            return path
        }
        let path = FFMpegFileReaderPixelBufferReuseTests.tempDirectory + "/clip.mp4"
        try? FileManager.default.removeItem(atPath: path)

        let width = 320
        let height = 240
        let frameCount = 60
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for i in 0 ..< frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let p = base.advanced(by: y * bytesPerRow + x * 4)
                    p[0] = UInt8(truncatingIfNeeded: x * 3 + i * 7)
                    p[1] = UInt8(truncatingIfNeeded: y * 2 + i * 5)
                    p[2] = UInt8(truncatingIfNeeded: (x ^ y) + i * 11)
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
        }
        input.markAsFinished()
        let finished = expectation(description: "finishWriting")
        writer.finishWriting {
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30.0)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        FFMpegFileReaderPixelBufferReuseTests.h264Path = path
        return path
    }

    // MARK: Helpers

    private func makeReader(path: String, reuse: Bool) throws -> FFMpegFileReader {
        return try XCTUnwrap(FFMpegFileReader(
            source: .file(path),
            passthroughDecoder: false,
            useHardwareAcceleration: false,
            selectedStream: .mediaType(.video),
            seek: nil,
            maxReadablePts: nil,
            ignoreEditList: false,
            reusesPixelBuffers: reuse
        ))
    }

    // Visible bytes only: rows past `width` are alignment padding that nothing reads.
    private func visibleBytes(_ pixelBuffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        var result = Data()
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount == 0 {
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let rowLength = CVPixelBufferGetWidth(pixelBuffer) * 4
            for y in 0 ..< CVPixelBufferGetHeight(pixelBuffer) {
                result.append(base.advanced(by: y * bytesPerRow), count: rowLength)
            }
        } else {
            for plane in 0 ..< planeCount {
                let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)!.assumingMemoryBound(to: UInt8.self)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                // Bi-planar CbCr interleaves two bytes per chroma sample.
                let bytesPerSample = (plane == 1) ? 2 : 1
                let rowLength = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) * bytesPerSample
                for y in 0 ..< CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) {
                    result.append(base.advanced(by: y * bytesPerRow), count: rowLength)
                }
            }
        }
        return result
    }

    private func decodeAll(path: String, reuse: Bool, argb: Bool, maxFrames: Int = 120, consume: (CMSampleBuffer) -> Void) throws -> Int {
        let reader = try makeReader(path: path, reuse: reuse)
        var count = 0
        while count < maxFrames {
            switch reader.readFrame(argb: argb) {
            case let .frame(frame):
                consume(frame.sampleBuffer)
                count += 1
            case .endOfStream:
                return count
            case .waitingForMoreData, .error:
                XCTFail("unexpected reader result")
                return count
            }
        }
        return count
    }

    private func referenceFrames(path: String, argb: Bool) throws -> [Data] {
        var frames: [Data] = []
        let _ = try decodeAll(path: path, reuse: false, argb: argb) { sampleBuffer in
            frames.append(self.visibleBytes(CMSampleBufferGetImageBuffer(sampleBuffer)!))
        }
        XCTAssertGreaterThan(frames.count, 10)
        return frames
    }

    // MARK: Tests

    private func checkIdenticalOutputWhenFramesAreReleased(path: String, argb: Bool) throws {
        let reference = try referenceFrames(path: path, argb: argb)

        var index = 0
        // IOSurface ids, not object addresses: a freed buffer's address can come back without a pool.
        var distinctSurfaces = Set<IOSurfaceID>()
        // Retained, so a recreated description cannot land at the same address.
        var firstFormat: CMFormatDescription?
        var formatWasRecreated = false
        let count = try decodeAll(path: path, reuse: true, argb: argb) { sampleBuffer in
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
            if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
                distinctSurfaces.insert(IOSurfaceGetID(surface))
            } else {
                XCTFail("frame is not IOSurface-backed")
            }
            let format = CMSampleBufferGetFormatDescription(sampleBuffer)!
            if let firstFormat {
                if firstFormat !== format {
                    formatWasRecreated = true
                }
            } else {
                firstFormat = format
            }
            XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: pixelBuffer))
            if index < reference.count {
                XCTAssertEqual(self.visibleBytes(pixelBuffer), reference[index], "frame \(index) differs with pixel buffer reuse")
            }
            index += 1
        }
        XCTAssertEqual(count, reference.count)
        // Each frame is released before the next one is decoded, so the pool recycles its buffers.
        XCTAssertLessThan(distinctSurfaces.count, count / 2, "pixel buffers were not reused")
        XCTAssertFalse(formatWasRecreated, "the format description was recreated")
    }

    private func checkHeldFramesAreNotOverwritten(path: String, argb: Bool) throws {
        let reference = try referenceFrames(path: path, argb: argb)

        // Hold every frame (as a display layer or a queued sample buffer does) until the end.
        var held: [CMSampleBuffer] = []
        let _ = try decodeAll(path: path, reuse: true, argb: argb) { sampleBuffer in
            held.append(sampleBuffer)
        }
        XCTAssertEqual(held.count, reference.count)
        XCTAssertEqual(Set(held.map { ObjectIdentifier(CMSampleBufferGetImageBuffer($0)!) }).count, held.count)
        for (i, sampleBuffer) in held.enumerated() where i < reference.count {
            XCTAssertEqual(self.visibleBytes(CMSampleBufferGetImageBuffer(sampleBuffer)!), reference[i], "held frame \(i) was overwritten")
        }
    }

    func testH264FramesAreIdenticalWithReuse() throws {
        try checkIdenticalOutputWhenFramesAreReleased(path: try makeH264Clip(), argb: false)
    }

    func testH264HeldFramesAreNotOverwritten() throws {
        try checkHeldFramesAreNotOverwritten(path: try makeH264Clip(), argb: false)
    }

    // VideoStickerFrameSource reads stickers as ARGB.
    func testStickerARGBFramesAreIdenticalWithReuse() throws {
        try checkIdenticalOutputWhenFramesAreReleased(path: try stickerPath(), argb: true)
    }

    func testStickerYUVFramesAreIdenticalWithReuse() throws {
        try checkIdenticalOutputWhenFramesAreReleased(path: try stickerPath(), argb: false)
    }

    func testStickerHeldFramesAreNotOverwritten() throws {
        try checkHeldFramesAreNotOverwritten(path: try stickerPath(), argb: true)
    }

    // Not an assertion on speed (the simulator is noisy): prints the decode cost both ways.
    func testDecodeTiming() throws {
        for (name, path, argb) in [("h264 320x240", try makeH264Clip(), false), ("vp9 sticker argb", try stickerPath(), true), ("vp9 sticker yuv", try stickerPath(), false)] {
            var best: [Bool: Double] = [:]
            var frames = 0
            for _ in 0 ..< 5 {
                for reuse in [false, true] {
                    let start = CFAbsoluteTimeGetCurrent()
                    frames = try decodeAll(path: path, reuse: reuse, argb: argb) { _ in }
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    best[reuse] = min(best[reuse] ?? .infinity, elapsed)
                }
            }
            let off = best[false]! * 1000.0 / Double(frames)
            let on = best[true]! * 1000.0 / Double(frames)
            print("FFMpegFileReaderPixelBufferReuse \(name): \(frames) frames, per frame \(String(format: "%.3f", off)) ms without reuse, \(String(format: "%.3f", on)) ms with reuse")
        }
    }

    // The two calls the device trace attributed 2.1 s to, in isolation.
    func testBufferAndFormatDescriptionMicroBenchmark() throws {
        let width = 512
        let height = 512
        let iterations = 500
        let ioSurfaceProperties: NSDictionary = ["IOSurfaceIsGlobal": true]
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 2048,
            kCVPixelBufferIOSurfacePropertiesKey as String: ioSurfaceProperties
        ]

        var start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< iterations {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &pixelBuffer)
            XCTAssertNotNil(pixelBuffer)
        }
        let create = CFAbsoluteTimeGetCurrent() - start

        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
        start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< iterations {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pixelBuffer)
            XCTAssertNotNil(pixelBuffer)
        }
        let pooled = CFAbsoluteTimeGetCurrent() - start

        var sample: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &sample)
        let buffer = try XCTUnwrap(sample)
        start = CFAbsoluteTimeGetCurrent()
        var format: CMVideoFormatDescription?
        for _ in 0 ..< iterations {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        }
        let describe = CFAbsoluteTimeGetCurrent() - start
        start = CFAbsoluteTimeGetCurrent()
        var matches = 0
        for _ in 0 ..< iterations {
            if CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: buffer) {
                matches += 1
            }
        }
        let match = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(matches, iterations)

        let us = { (t: Double) in String(format: "%.2f", t * 1e6 / Double(iterations)) }
        print("FFMpegFileReaderPixelBufferReuse micro: CVPixelBufferCreate \(us(create)) us, pool \(us(pooled)) us, CMVideoFormatDescriptionCreateForImageBuffer \(us(describe)) us, MatchesImageBuffer \(us(match)) us")
    }
}
