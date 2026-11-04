import XCTest
import CoreMedia
import CoreVideo
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

final class SoftwareVideoSourceHardwareFrameTests: XCTestCase {
    private func readFrames(path: String, count: Int) throws -> [MediaTrackFrame] {
        let source = SoftwareVideoSource(path: path, hintVP9: false, unpremultiplyAlpha: true, useHardwareAcceleration: true, reusePixelBuffers: true)
        var frames: [MediaTrackFrame] = []
        for _ in 0 ..< count * 2 {
            if let frame = source.readFrame(maxPts: nil).0 {
                frames.append(frame)
                if frames.count == count {
                    break
                }
            }
        }
        return frames
    }

    func testHardwareFramesAreShownUntagged() throws {
        let path = try MediaTestSupport.resourcePath("h264_709", "mp4")
        let frames = try readFrames(path: path, count: 20)
        XCTAssertEqual(frames.count, 20)
        for frame in frames {
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame.sampleBuffer))
            XCTAssertNil(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil))
            XCTAssertNil(CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil))
            XCTAssertNil(CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil))
            XCTAssertNil(CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil))
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(frame.sampleBuffer))
            XCTAssertNil(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix))
            XCTAssertNil(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries))
            XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: buffer))
        }
    }

    func testHardwareFramesShareOneFormatDescription() throws {
        let path = try MediaTestSupport.resourcePath("h264_709", "mp4")
        let frames = try readFrames(path: path, count: 20)
        XCTAssertEqual(frames.count, 20)
        let formats = frames.compactMap { CMSampleBufferGetFormatDescription($0.sampleBuffer) }
        let distinct = Set(formats.map { ObjectIdentifier($0) })
        XCTAssertEqual(distinct.count, 1, "a format description was created per frame")
    }
}
