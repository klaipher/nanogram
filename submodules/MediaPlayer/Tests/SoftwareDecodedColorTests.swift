import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

final class SoftwareDecodedColorTests: XCTestCase {
    private static var clips: [String: String] = [:]

    private func makeReader(path: String, hardware: Bool = false) throws -> FFMpegFileReader {
        return try XCTUnwrap(FFMpegFileReader(
            source: .file(path),
            passthroughDecoder: false,
            useHardwareAcceleration: hardware,
            selectedStream: .mediaType(.video),
            seek: nil,
            maxReadablePts: nil
        ))
    }

    private func readBuffers(_ reader: FFMpegFileReader, count: Int = 10) -> [CMSampleBuffer] {
        var result: [CMSampleBuffer] = []
        while result.count < count {
            guard case let .frame(frame) = reader.readFrame() else {
                break
            }
            result.append(frame.sampleBuffer)
        }
        return result
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        return CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    private func makeClip(name: String, codec: AVVideoCodecType, pixelFormat: OSType, profile: String?, fill: (CVPixelBuffer, Int) -> Void) throws -> String {
        if let path = SoftwareDecodedColorTests.clips[name] {
            return path
        }
        let path = MediaTestSupport.tempDirectory + "/\(name).mp4"
        try? FileManager.default.removeItem(atPath: path)
        let width = 128
        let height = 96
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        var compression: [String: Any] = [AVVideoAllowFrameReorderingKey: false]
        if let profile {
            compression[AVVideoProfileLevelKey] = profile
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0 ..< 10 {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            fill(buffer, i)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 60.0), .success)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        SoftwareDecodedColorTests.clips[name] = path
        return path
    }

    private static func fillBiPlanar(_ buffer: CVPixelBuffer, luma: (Int, Int) -> Int, bytesPerSample: Int, shift: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let value = luma(column, row)
                if bytesPerSample == 1 {
                    y.storeBytes(of: UInt8(value), toByteOffset: row * yRow + column, as: UInt8.self)
                } else {
                    y.storeBytes(of: UInt16(value << shift), toByteOffset: row * yRow + column * 2, as: UInt16.self)
                }
            }
        }
        for row in 0 ..< height / 2 {
            for column in 0 ..< width {
                if bytesPerSample == 1 {
                    uv.storeBytes(of: UInt8(128), toByteOffset: row * uvRow + column, as: UInt8.self)
                } else {
                    uv.storeBytes(of: UInt16(512 << shift), toByteOffset: row * uvRow + column * 2, as: UInt16.self)
                }
            }
        }
    }

    func testSoftwareFramesCarryTheStreamColours() throws {
        let path = try MediaTestSupport.resourcePath("h264_709", "mp4")
        let buffers = readBuffers(try makeReader(path: path))
        XCTAssertEqual(buffers.count, 10)
        for sampleBuffer in buffers {
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sampleBuffer))
            XCTAssertEqual(attachment(buffer, kCVImageBufferYCbCrMatrixKey), kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            XCTAssertEqual(attachment(buffer, kCVImageBufferColorPrimariesKey), kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            XCTAssertEqual(attachment(buffer, kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_ITU_R_709_2 as String)
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sampleBuffer))
            XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        }
    }

    func testUntaggedStreamStaysUntagged() throws {
        let path = try MediaTestSupport.resourcePath("h264_bframes", "mp4")
        let buffers = readBuffers(try makeReader(path: path))
        XCTAssertEqual(buffers.count, 10)
        for sampleBuffer in buffers {
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sampleBuffer))
            XCTAssertNil(attachment(buffer, kCVImageBufferYCbCrMatrixKey))
            XCTAssertNil(attachment(buffer, kCVImageBufferColorPrimariesKey))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }

    func testFullRangeStreamUsesFullRangeBuffers() throws {
        let path = try makeClip(name: "h264_full_range", codec: .h264, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, profile: AVVideoProfileLevelH264HighAutoLevel) { buffer, _ in
            SoftwareDecodedColorTests.fillBiPlanar(buffer, luma: { column, _ in column < 64 ? 0 : 255 }, bytesPerSample: 1, shift: 0)
        }
        let buffers = readBuffers(try makeReader(path: path))
        XCTAssertEqual(buffers.count, 10)
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(try XCTUnwrap(buffers.last)))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let black = Int(y[48 * row + 16])
        let white = Int(y[48 * row + 112])
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        XCTAssertLessThanOrEqual(black, 4)
        XCTAssertGreaterThanOrEqual(white, 251)
    }

    func testTenBitStreamDecodesToTenBitBuffers() throws {
        let path = try makeClip(name: "hevc_main10", codec: .hevc, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, profile: kVTProfileLevel_HEVC_Main10_AutoLevel as String) { buffer, i in
            SoftwareDecodedColorTests.fillBiPlanar(buffer, luma: { column, row in 64 + ((column * 7 + row * 3 + i) % 876) }, bytesPerSample: 2, shift: 6)
        }
        let software = readBuffers(try makeReader(path: path))
        XCTAssertEqual(software.count, 10, "10-bit frames were dropped")
        guard let first = software.first, let buffer = CMSampleBufferGetImageBuffer(first) else {
            return
        }
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let hardware = readBuffers(try makeReader(path: path, hardware: true))
        guard let hardwareFirst = hardware.first, let hardwareBuffer = CMSampleBufferGetImageBuffer(hardwareFirst), CVPixelBufferGetPixelFormatType(hardwareBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
            throw XCTSkip("VideoToolbox does not give x420 for HEVC Main10 here")
        }
        for (softwareSample, hardwareSample) in zip(software, hardware) {
            let softwareBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(softwareSample))
            let hardwareBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(hardwareSample))
            XCTAssertTrue(MediaTestSupport.visibleBytes(softwareBuffer) == MediaTestSupport.visibleBytes(hardwareBuffer), "software and VideoToolbox 10-bit pixels differ")
        }
    }

    func testUntaggedPresentationDropsTheStreamColours() throws {
        let path = try MediaTestSupport.resourcePath("h264_709", "mp4")
        let source = SoftwareVideoSource(path: path, hintVP9: false, unpremultiplyAlpha: true, useHardwareAcceleration: false)
        var frames: [MediaTrackFrame] = []
        for _ in 0 ..< 20 where frames.count < 5 {
            if let frame = source.readFrame(maxPts: nil).0 {
                frames.append(frame)
            }
        }
        XCTAssertEqual(frames.count, 5)
        for frame in frames {
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame.sampleBuffer))
            XCTAssertNil(attachment(buffer, kCVImageBufferYCbCrMatrixKey))
        }
    }
}
