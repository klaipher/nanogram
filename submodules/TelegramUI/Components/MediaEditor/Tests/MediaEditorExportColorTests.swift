import XCTest
import AVFoundation
import CoreVideo
@testable import MediaEditor

/// Edited videos (stories, edited video messages, avatars) were written without colour tags.
/// VideoToolbox encodes the composer's BGRA frames with the BT.709 matrix, but Apple's decoders
/// read untagged video up to 720x576 as BT.601, so colours shifted (pure red decoded as about
/// (237, 13, 0) at 480x480). The export settings now carry BT.709 tags.
final class MediaEditorExportColorTests: XCTestCase {
    private func writeSolidVideo(url: URL, width: Int, height: Int, settings: [String: Any], bgra: (UInt8, UInt8, UInt8)) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: UInt32(width),
            kCVPixelBufferHeightKey as String: UInt32(height)
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0 ..< 10 {
            while !input.isReadyForMoreMediaData {
                usleep(1000)
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixelBuffer)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let p = base + y * bytesPerRow + x * 4
                    p[0] = bgra.0
                    p[1] = bgra.1
                    p[2] = bgra.2
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
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let p = base + (CVPixelBufferGetHeight(pixelBuffer) / 2) * CVPixelBufferGetBytesPerRow(pixelBuffer) + (CVPixelBufferGetWidth(pixelBuffer) / 2) * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]), matrix)
    }

    private func settings(width: Int, height: Int, codec: AVVideoCodecType, tag: Bool) -> [String: Any] {
        return mediaEditorExportVideoSettings(codecType: codec, compressionProperties: [
            AVVideoAverageBitRateKey: 2000 * 1000
        ], width: width, height: height, tagBT709: tag)
    }

    func testExportedPureRedDecodesAsPureRed() async throws {
        // 480x480 and 640x360 are below the size where untagged video is read as BT.601.
        for (width, height) in [(480, 480), (640, 360), (720, 1280)] {
            for codec in [AVVideoCodecType.h264, AVVideoCodecType.hevc] {
                let url = URL(fileURLWithPath: NSTemporaryDirectory() + "red-\(width)x\(height)-\(codec.rawValue).mp4")
                try self.writeSolidVideo(url: url, width: width, height: height, settings: self.settings(width: width, height: height, codec: codec, tag: true), bgra: (0, 0, 255))
                let decoded = try await self.decodedCentre(url: url)
                XCTAssertEqual(decoded.matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, "\(width)x\(height) \(codec.rawValue)")
                XCTAssertEqual(decoded.r, 255, accuracy: 2, "\(width)x\(height) \(codec.rawValue): \(decoded)")
                XCTAssertEqual(decoded.g, 0, accuracy: 2, "\(width)x\(height) \(codec.rawValue): \(decoded)")
                XCTAssertEqual(decoded.b, 0, accuracy: 2, "\(width)x\(height) \(codec.rawValue): \(decoded)")
            }
        }
    }

    // What the export did before: the same frames without tags decode with a colour shift at
    // video-message size. Kept as a guard that the test above measures something.
    func testUntaggedSmallVideoDecodesShifted() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "red-untagged-480.mp4")
        try self.writeSolidVideo(url: url, width: 480, height: 480, settings: self.settings(width: 480, height: 480, codec: .h264, tag: false), bgra: (0, 0, 255))
        let decoded = try await self.decodedCentre(url: url)
        print("MediaEditorExportColorTests: untagged 480x480 red decodes as \(decoded)")
        XCTAssertNil(decoded.matrix)
        XCTAssertGreaterThan(abs(decoded.r - 255) + decoded.g + decoded.b, 6)
    }

    func testVP9SettingsStayUntagged() {
        let settings = mediaEditorExportVideoSettings(codecType: "VP9", compressionProperties: [:], width: 512, height: 512, tagBT709: false)
        XCTAssertNil(settings[AVVideoColorPropertiesKey])
    }
}
