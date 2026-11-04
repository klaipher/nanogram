import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import VideoToolbox
import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

private struct ClipColor {
    let primaries: String
    let transfer: String
    let matrix: String
}

private func writeClip(codec: AVVideoCodecType, profile: String, pixelFormat: OSType, color: ClipColor, renderSpace: CGColorSpace, width: Int = 320, height: Int = 240) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "passthrough_color_\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: profile],
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: color.primaries, AVVideoTransferFunctionKey: color.transfer, AVVideoYCbCrMatrixKey: color.matrix]
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let context = CIContext()
    for index in 0 ..< 10 {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, pixelFormat, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, color.primaries as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, color.transfer as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, color.matrix as CFString, .shouldPropagate)
        var image = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02, colorSpace: renderSpace)!).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        image = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9, colorSpace: renderSpace)!).cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height)).composited(over: image)
        context.render(image, to: buffer, bounds: image.extent, colorSpace: renderSpace)
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting {
        done.signal()
    }
    done.wait()
    XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    return url
}

private func firstSample(url: URL) throws -> (CMFormatDescription, CMSampleBuffer) {
    let asset = AVURLAsset(url: url)
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var sample: CMSampleBuffer?
    while let next = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(next) > 0, CMSampleBufferGetDataBuffer(next) != nil {
            sample = next
            break
        }
    }
    reader.cancelReading()
    let description = try XCTUnwrap(track.formatDescriptions.first.map { $0 as! CMFormatDescription })
    return (description, try XCTUnwrap(sample))
}

private func resample(_ sample: CMSampleBuffer, with description: CMFormatDescription) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo()
    CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
    var size = CMSampleBufferGetSampleSize(sample, at: 0)
    var result: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: CMSampleBufferGetDataBuffer(sample), formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result), noErr)
    return try XCTUnwrap(result)
}

private struct DecodedFrame {
    let transfer: String?
    let primaries: String?
    let matrix: String?
    let pixelFormat: OSType
    let darkLuma: Int
    let brightLuma: Int
}

private func decode(_ sample: CMSampleBuffer, description: CMFormatDescription, pixelFormat requestedPixelFormat: OSType?) throws -> DecodedFrame {
    var session: VTDecompressionSession?
    let attributes = requestedPixelFormat.map { [kCVPixelBufferPixelFormatTypeKey as String: $0] as CFDictionary }
    XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session), noErr)
    let decompression = try XCTUnwrap(session)
    defer {
        VTDecompressionSessionInvalidate(decompression)
    }
    var decoded: CVImageBuffer?
    let status = VTDecompressionSessionDecodeFrame(decompression, sampleBuffer: sample, flags: [], infoFlagsOut: nil, outputHandler: { status, _, imageBuffer, _, _ in
        XCTAssertEqual(status, noErr)
        decoded = imageBuffer
    })
    XCTAssertEqual(status, noErr)
    VTDecompressionSessionWaitForAsynchronousFrames(decompression)
    let buffer = try XCTUnwrap(decoded)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
    let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let row = CVPixelBufferGetHeightOfPlane(buffer, 0) / 2
    func luma(_ x: Int) -> Int {
        if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            return Int(base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt16.self)[x] >> 6)
        }
        return Int(base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)[x])
    }
    return DecodedFrame(
        transfer: CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
        primaries: CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String,
        matrix: CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String,
        pixelFormat: pixelFormat,
        darkLuma: luma(width / 4),
        brightLuma: luma(3 * width / 4)
    )
}

private func atom(_ description: CMFormatDescription, _ name: String) throws -> Data {
    let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any])
    return try XCTUnwrap(atoms[name] as? Data)
}

final class PassthroughFormatDescriptionColorTests: XCTestCase {
    private func compare(url: URL, atomName: String, pixelFormat: OSType? = nil, build: (UInt32, Int32, Int32, Data) -> CMFormatDescription?, file: StaticString = #filePath, line: UInt = #line) throws {
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let (assetDescription, sample) = try firstSample(url: url)
        let dimensions = CMVideoFormatDescriptionGetDimensions(assetDescription)
        let ours = try XCTUnwrap(build(CMFormatDescriptionGetMediaSubType(assetDescription), dimensions.width, dimensions.height, try atom(assetDescription, atomName)))
        let expected = try decode(sample, description: assetDescription, pixelFormat: pixelFormat)
        let actual = try decode(try resample(sample, with: ours), description: ours, pixelFormat: pixelFormat)
        XCTAssertEqual(actual.transfer, expected.transfer, "transfer", file: file, line: line)
        XCTAssertEqual(actual.primaries, expected.primaries, "primaries", file: file, line: line)
        XCTAssertEqual(actual.matrix, expected.matrix, "matrix", file: file, line: line)
        XCTAssertEqual(actual.pixelFormat, expected.pixelFormat, "pixel format", file: file, line: line)
        XCTAssertEqual(actual.darkLuma, expected.darkLuma, accuracy: 2, "dark luma", file: file, line: line)
        XCTAssertEqual(actual.brightLuma, expected.brightLuma, accuracy: 2, "bright luma", file: file, line: line)
    }

    func testHLGHEVCDecodesLikeTheContainerDescription() throws {
        let url = try writeClip(codec: .hevc, profile: kVTProfileLevel_HEVC_Main10_AutoLevel as String, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, color: ClipColor(primaries: AVVideoColorPrimaries_ITU_R_2020, transfer: AVVideoTransferFunction_ITU_R_2100_HLG, matrix: AVVideoYCbCrMatrix_ITU_R_2020), renderSpace: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!)
        try self.compare(url: url, atomName: "hvcC", pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, build: FFMpegMediaFrameSourceContextHelpers.createFormatDescriptionFromHEVCCodecData)
    }

    func testPQHEVCDecodesLikeTheContainerDescription() throws {
        let url = try writeClip(codec: .hevc, profile: kVTProfileLevel_HEVC_Main10_AutoLevel as String, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, color: ClipColor(primaries: AVVideoColorPrimaries_ITU_R_2020, transfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ, matrix: AVVideoYCbCrMatrix_ITU_R_2020), renderSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!)
        try self.compare(url: url, atomName: "hvcC", pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, build: FFMpegMediaFrameSourceContextHelpers.createFormatDescriptionFromHEVCCodecData)
    }

    func testFullRangeH264DecodesLikeTheContainerDescription() throws {
        let url = try writeClip(codec: .h264, profile: AVVideoProfileLevelH264HighAutoLevel, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, color: ClipColor(primaries: AVVideoColorPrimaries_ITU_R_709_2, transfer: AVVideoTransferFunction_ITU_R_709_2, matrix: AVVideoYCbCrMatrix_ITU_R_709_2), renderSpace: CGColorSpace(name: CGColorSpace.itur_709)!)
        try self.compare(url: url, atomName: "avcC", build: FFMpegMediaFrameSourceContextHelpers.createFormatDescriptionFromAVCCodecData)
    }

    func testSDH264DecodesLikeTheContainerDescription() throws {
        let url = try writeClip(codec: .h264, profile: AVVideoProfileLevelH264HighAutoLevel, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: ClipColor(primaries: AVVideoColorPrimaries_SMPTE_C, transfer: AVVideoTransferFunction_ITU_R_709_2, matrix: AVVideoYCbCrMatrix_ITU_R_601_4), renderSpace: CGColorSpace(name: CGColorSpace.sRGB)!, width: 640, height: 480)
        try self.compare(url: url, atomName: "avcC", build: FFMpegMediaFrameSourceContextHelpers.createFormatDescriptionFromAVCCodecData)
    }
}
