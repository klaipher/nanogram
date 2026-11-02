import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import Camera
@testable import CameraNeo

/// CameraNeo circles were tagged with the camera's BT.601 matrix while VideoToolbox converted the
/// processor's BGRA frames with BT.709, so players decoding by the tag shifted colours (pure red
/// decoded as about (234, 0, 2), skin turned magenta). The frames written through the processor's
/// pool and the recorder's settings must decode back to what was drawn.
final class RoundVideoColorTests: XCTestCase {
    private let width = RoundVideoFrameProcessor.outputWidth
    private let height = RoundVideoFrameProcessor.outputHeight

    // What the front camera delivers: NV12 tagged 709 primaries and transfer with the 601 matrix.
    private func cameraSource() throws -> VideoFrameSource {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription), noErr)
        return VideoFrameSource(pixelBuffer: buffer, formatDescription: try XCTUnwrap(formatDescription), position: .front, orientation: .portrait)
    }

    private func writeSolidVideo(url: URL, source: VideoFrameSource, rgb: (UInt8, UInt8, UInt8)) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let settings = VideoRecorder.videoSettings(source: source)
        XCTAssertTrue(writer.canApply(outputSettings: settings, forMediaType: .video))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // The processor renders into buffers from a pool with these attributes.
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, RoundVideoFrameProcessor.outputPixelBufferAttributes as CFDictionary, &pool), kCVReturnSuccess)
        let outputPool = try XCTUnwrap(pool)

        for i in 0 ..< 10 {
            while !input.isReadyForMoreMediaData {
                usleep(1000)
            }
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0 ..< self.height {
                for x in 0 ..< self.width {
                    let p = base + y * bytesPerRow + x * 4
                    p[0] = rgb.2
                    p[1] = rgb.1
                    p[2] = rgb.0
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30)))
        }
        input.markAsFinished()
        let finished = self.expectation(description: "finished")
        writer.finishWriting {
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 30.0)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    private func decodedCentre(url: URL) async throws -> (r: Int, g: Int, b: Int, matrix: String?) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let formatDescription = try XCTUnwrap(formatDescriptions.first)
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?
        let matrix = extensions?[kCVImageBufferYCbCrMatrixKey] as? String
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sampleBuffer = try XCTUnwrap(output.copyNextSampleBuffer())
        let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sampleBuffer))
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let p = base + (CVPixelBufferGetHeight(pixelBuffer) / 2) * CVPixelBufferGetBytesPerRow(pixelBuffer) + (CVPixelBufferGetWidth(pixelBuffer) / 2) * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]), matrix)
    }

    func testCircleColoursDecodeAsDrawn() async throws {
        let source = try self.cameraSource()
        let colours: [(name: String, rgb: (UInt8, UInt8, UInt8))] = [
            ("red", (255, 0, 0)),
            ("skin", (220, 160, 130))
        ]
        for colour in colours {
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "round-\(colour.name).mp4")
            try self.writeSolidVideo(url: url, source: source, rgb: colour.rgb)
            let decoded = try await self.decodedCentre(url: url)
            print("RoundVideoColorTests: \(colour.name) \(colour.rgb) decodes as \(decoded)")
            XCTAssertEqual(decoded.matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, colour.name)
            XCTAssertEqual(decoded.r, Int(colour.rgb.0), accuracy: 2, "\(colour.name): \(decoded)")
            XCTAssertEqual(decoded.g, Int(colour.rgb.1), accuracy: 2, "\(colour.name): \(decoded)")
            XCTAssertEqual(decoded.b, Int(colour.rgb.2), accuracy: 2, "\(colour.name): \(decoded)")
        }
    }

    func testTagKeepsSourcePrimariesAndTransfer() throws {
        let properties = RoundVideoFrameProcessor.videoColorProperties(from: try self.cameraSource())
        XCTAssertEqual(properties[AVVideoColorPrimariesKey] as? String, AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(properties[AVVideoTransferFunctionKey] as? String, AVVideoTransferFunction_ITU_R_709_2)
        XCTAssertEqual(properties[AVVideoYCbCrMatrixKey] as? String, AVVideoYCbCrMatrix_ITU_R_709_2)
    }
}
