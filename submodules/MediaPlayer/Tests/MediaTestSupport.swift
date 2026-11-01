import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import UniversalMediaPlayer

// Shared helpers for the FFmpeg reader tests.
enum MediaTestSupport {
    static func resourcePath(_ name: String, _ ext: String) throws -> String {
        let bundles = [Bundle(for: MediaTestSupportAnchor.self), Bundle.main] + Bundle.allBundles
        for bundle in bundles {
            if let path = bundle.path(forResource: name, ofType: ext) {
                return path
            }
        }
        throw XCTSkip("\(name).\(ext) is not in the test bundle")
    }

    static var tempDirectory: String = {
        let path = NSTemporaryDirectory() + "MediaTestSupport"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    // Visible bytes only: rows past `width` are alignment padding that nothing reads.
    static func visibleBytes(_ pixelBuffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        var result = Data()
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount == 0 {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
                return result
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let rowLength = CVPixelBufferGetWidth(pixelBuffer) * 4
            for y in 0 ..< CVPixelBufferGetHeight(pixelBuffer) {
                result.append(base.advanced(by: y * bytesPerRow), count: rowLength)
            }
        } else {
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            for plane in 0 ..< planeCount {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)?.assumingMemoryBound(to: UInt8.self) else {
                    continue
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                // Bi-planar CbCr interleaves two bytes per chroma sample.
                let isInterleavedChroma = plane == 1 && format != kCVPixelFormatType_420YpCbCr8Planar
                let rowLength = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) * (isInterleavedChroma ? 2 : 1)
                for y in 0 ..< CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) {
                    result.append(base.advanced(by: y * bytesPerRow), count: rowLength)
                }
            }
        }
        return result
    }

    struct DecodedFrame: Equatable {
        let pts: CMTime
        let bytes: Data
    }

    static func frame(_ frame: MediaTrackFrame) -> DecodedFrame {
        let pts = CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer)
        if let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
            return DecodedFrame(pts: pts, bytes: visibleBytes(imageBuffer))
        }
        var bytes = Data()
        if let dataBuffer = CMSampleBufferGetDataBuffer(frame.sampleBuffer) {
            let length = CMBlockBufferGetDataLength(dataBuffer)
            bytes = Data(count: length)
            bytes.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    let _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
                }
            }
        }
        return DecodedFrame(pts: pts, bytes: bytes)
    }

    // Reads up to `maxFrames` frames, stopping at the end of the stream.
    static func readFrames(_ reader: FFMpegFileReader, argb: Bool = false, maxFrames: Int = 1000) -> [DecodedFrame] {
        var frames: [DecodedFrame] = []
        while frames.count < maxFrames {
            switch reader.readFrame(argb: argb) {
            case let .frame(value):
                frames.append(frame(value))
            case .endOfStream:
                return frames
            case .waitingForMoreData, .error:
                XCTFail("unexpected reader result")
                return frames
            }
        }
        return frames
    }

    // A clip written by AVAssetWriter, cached per configuration for the test run.
    private static var clips: [String: String] = [:]

    static func makeClip(width: Int, height: Int, frameCount: Int, frameReordering: Bool, variableFrameDurations: Bool, color709: Bool) throws -> String {
        let key = "\(width)x\(height)-\(frameCount)-\(frameReordering)-\(variableFrameDurations)-\(color709)"
        if let path = clips[key] {
            return path
        }
        let path = tempDirectory + "/clip-\(key).mp4"
        try? FileManager.default.removeItem(atPath: path)

        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: frameReordering,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        ]
        if color709 {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for i in 0 ..< frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
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
                    let cx = (x + i * 3) % width
                    let cy = (y + i * 2) % height
                    p[0] = UInt8(truncatingIfNeeded: cx * 2)
                    p[1] = UInt8(truncatingIfNeeded: cy * 3)
                    p[2] = UInt8(truncatingIfNeeded: ((cx / 16 + cy / 16) % 2) * 200 + i)
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            // 1/600 s units; uneven durations make FFmpeg estimate the frame rate from packets.
            let pts = variableFrameDurations ? CMTime(value: CMTimeValue(i * 20 + (i % 3 == 0 ? 0 : 3)), timescale: 600) : CMTime(value: CMTimeValue(i), timescale: 30)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: pts))
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 60.0), .success)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        clips[key] = path
        return path
    }
}

final class MediaTestSupportAnchor {
}
