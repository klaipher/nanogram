import XCTest
import CoreMedia
import CoreVideo
@testable import TelegramMediaPlayer

// FFmpeg's VideoToolbox hwaccel (ChunkMediaPlayerV2 on device) rewrote the colour attachments of
// every decoded frame and read all of them back through IOSurface IPC (0.74 s in a device session).
// The local patch in libavcodec/videotoolbox.c skips that when VideoToolbox has already tagged the
// buffer the same way. These tests pin the attachments the frames end up with, which are the ones
// unpatched FFmpeg 9.0.2 produced for these files (checked on macOS with the same decoder).
final class FFMpegVideoToolboxAttachmentTests: XCTestCase {
    private func makeReader(path: String, hardware: Bool) throws -> FFMpegFileReader {
        return try XCTUnwrap(FFMpegFileReader(
            source: .file(path),
            passthroughDecoder: false,
            useHardwareAcceleration: hardware,
            selectedStream: .mediaType(.video),
            seek: nil,
            maxReadablePts: nil
        ))
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> CFTypeRef? {
        return CVBufferCopyAttachment(buffer, key, nil)
    }

    // Decodes with the hwaccel and hands each VideoToolbox buffer to `check`.
    private func decodeHardwareFrames(path: String, check: (CVPixelBuffer) -> Void) throws -> Int {
        let reader = try makeReader(path: path, hardware: true)
        var count = 0
        while true {
            switch reader.readFrame() {
            case let .frame(frame):
                let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame.sampleBuffer))
                check(buffer)
                count += 1
            case .endOfStream:
                return count
            case .waitingForMoreData, .error:
                XCTFail("unexpected reader result")
                return count
            }
        }
    }

    private func requireHardwareFrames(path: String) throws {
        let reader = try makeReader(path: path, hardware: true)
        guard case let .frame(frame) = reader.readFrame(), let buffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
            throw XCTSkip("no frame from the VideoToolbox hwaccel")
        }
        if attachment(buffer, "ColorInfoGuessedBy" as CFString) == nil {
            let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as NSDictionary?
            throw XCTSkip("frames do not come from VideoToolbox here (format \(CVPixelBufferGetPixelFormatType(buffer)), attachments \(String(describing: attachments)))")
        }
    }

    func testTaggedStreamKeepsItsColourAttachments() throws {
        let path = try MediaTestSupport.resourcePath("h264_709", "mp4")
        try requireHardwareFrames(path: path)
        let count = try decodeHardwareFrames(path: path) { buffer in
            XCTAssertEqual(attachment(buffer, kCVImageBufferYCbCrMatrixKey) as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            XCTAssertEqual(attachment(buffer, kCVImageBufferColorPrimariesKey) as? String, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            XCTAssertEqual(attachment(buffer, kCVImageBufferTransferFunctionKey) as? String, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
            XCTAssertEqual(attachment(buffer, kCVImageBufferChromaLocationTopFieldKey) as? String, kCVImageBufferChromaLocation_Left as String)
            XCTAssertNotNil(attachment(buffer, kCVImageBufferCGColorSpaceKey))
            XCTAssertNil(attachment(buffer, kCVImageBufferPixelAspectRatioKey))
            XCTAssertNil(attachment(buffer, kCVImageBufferGammaLevelKey))
        }
        XCTAssertEqual(count, 60)
    }

    // VideoToolbox guesses BT.709 for an untagged stream; FFmpeg removes the guess.
    func testUntaggedStreamHasNoColourAttachments() throws {
        let path = try MediaTestSupport.resourcePath("h264_bframes", "mp4")
        try requireHardwareFrames(path: path)
        let count = try decodeHardwareFrames(path: path) { buffer in
            XCTAssertNil(attachment(buffer, kCVImageBufferYCbCrMatrixKey))
            XCTAssertNil(attachment(buffer, kCVImageBufferColorPrimariesKey))
            XCTAssertNil(attachment(buffer, kCVImageBufferTransferFunctionKey))
            XCTAssertNil(attachment(buffer, kCVImageBufferChromaLocationTopFieldKey))
            XCTAssertNil(attachment(buffer, kCVImageBufferCGColorSpaceKey))
        }
        XCTAssertEqual(count, 60)
    }

    // H.264 decoding is bit-exact, so the hwaccel frames must equal FFmpeg's software frames.
    func testHardwareFramesMatchSoftwareFrames() throws {
        for name in ["h264_709", "h264_bframes", "h264_bframes_editlist"] {
            let path = try MediaTestSupport.resourcePath(name, "mp4")
            try requireHardwareFrames(path: path)
            let software = MediaTestSupport.readFrames(try makeReader(path: path, hardware: false))
            var hardware: [MediaTestSupport.DecodedFrame] = []
            let reader = try makeReader(path: path, hardware: true)
            while case let .frame(frame) = reader.readFrame() {
                let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame.sampleBuffer))
                guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                    throw XCTSkip("VideoToolbox output is not 420v here")
                }
                hardware.append(MediaTestSupport.frame(frame))
            }
            XCTAssertEqual(hardware.count, software.count, name)
            for i in 0 ..< min(hardware.count, software.count) {
                XCTAssertEqual(hardware[i].pts, software[i].pts, "\(name) frame \(i)")
                XCTAssertTrue(hardware[i].bytes == software[i].bytes, "\(name) frame \(i): pixels differ")
            }
        }
    }

    // Not an assertion on speed: prints the hwaccel decode cost per frame.
    func testHardwareDecodeCost() throws {
        let path = try MediaTestSupport.makeClip(width: 1280, height: 720, frameCount: 120, frameReordering: true, variableFrameDurations: false, color709: true)
        try requireHardwareFrames(path: path)
        var best = Double.infinity
        var frames = 0
        for _ in 0 ..< 5 {
            let start = CFAbsoluteTimeGetCurrent()
            frames = try decodeHardwareFrames(path: path) { _ in }
            best = min(best, CFAbsoluteTimeGetCurrent() - start)
        }
        print("FFMpegVideoToolboxAttachment 1280x720 bt709: \(frames) frames, \(String(format: "%.3f", best * 1000.0 / Double(frames))) ms per frame")
    }
}
