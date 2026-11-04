import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

private func writeSolidColorH264(red: UInt8, green: UInt8, blue: UInt8, width: Int, height: Int) throws -> String {
    let path = NSTemporaryDirectory() + "preview_color_\(UUID().uuidString).mp4"
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0 ..< 10 {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ] as CFDictionary, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixel = base.advanced(by: y * bytesPerRow + x * 4)
                pixel[0] = blue
                pixel[1] = green
                pixel[2] = red
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 25)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting {
        done.signal()
    }
    done.wait()
    XCTAssertEqual(writer.status, .completed)
    return path
}

private func centerPixelInSRGB(_ image: CGImage) -> (Int, Int, Int) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .none
    let x = CGFloat(image.width / 2)
    let y = CGFloat(image.height / 2)
    context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(data[0]), Int(data[1]), Int(data[2]))
}

final class SoftwareVideoPreviewColorTests: XCTestCase {
#if os(macOS)
    func testRenderedPreviewIsTaggedSRGBAndKeepsItsColour() throws {
        let path = try writeSolidColorH264(red: 191, green: 0, blue: 0, width: 320, height: 240)
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let source = SoftwareVideoSource(path: path, hintVP9: false, unpremultiplyAlpha: false)
        let (image, _, _, _) = source.readImage()
        let cgImage = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cgImage.colorSpace?.name, CGColorSpace.sRGB)
        let (r, g, b) = centerPixelInSRGB(cgImage)
        XCTAssertEqual(r, 191, accuracy: 8)
        XCTAssertEqual(g, 0, accuracy: 8)
        XCTAssertEqual(b, 0, accuracy: 8)
    }
#endif

    private func formatDescription(extensions: [CFString: Any]) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AV1, width: 1920, height: 1080, extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }

    func testAssetReaderKeepsTenBitAV1() throws {
        let eightBit = try self.formatDescription(extensions: [kCMFormatDescriptionExtension_BitsPerComponent: 8])
        XCTAssertEqual(AVAssetVideoDataReader.outputPixelFormat(formatDescription: eightBit), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let untagged = try self.formatDescription(extensions: [:])
        XCTAssertEqual(AVAssetVideoDataReader.outputPixelFormat(formatDescription: untagged), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let tenBit = try self.formatDescription(extensions: [kCMFormatDescriptionExtension_BitsPerComponent: 10])
        XCTAssertEqual(AVAssetVideoDataReader.outputPixelFormat(formatDescription: tenBit), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)

        let hlg = try self.formatDescription(extensions: [kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG])
        XCTAssertEqual(AVAssetVideoDataReader.outputPixelFormat(formatDescription: hlg), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)

        let pq = try self.formatDescription(extensions: [kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ])
        XCTAssertEqual(AVAssetVideoDataReader.outputPixelFormat(formatDescription: pq), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    }
}
