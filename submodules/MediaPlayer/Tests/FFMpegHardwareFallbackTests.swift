import XCTest
import CoreMedia
@testable import TelegramMediaPlayer

// FFmpeg calls the get_format callback again, without the VideoToolbox format, when the hwaccel
// setup fails (no device, session limit, a profile VideoToolbox cannot decode). The callback used
// to return VideoToolbox unconditionally, which FFmpeg rejects as "not in possible list", so the
// decoder produced no frames at all. It must fall back to the software format.
final class FFMpegHardwareFallbackTests: XCTestCase {
    private func makeReader(path: String, hardware: Bool, forceFailure: Bool) throws -> FFMpegFileReader {
        return try XCTUnwrap(FFMpegFileReader(
            source: .file(path),
            passthroughDecoder: false,
            useHardwareAcceleration: hardware,
            skipLoopFilter: false,
            selectedStream: .mediaType(.video),
            seek: nil,
            maxReadablePts: nil,
            ignoreEditList: false,
            forceHardwareSetupFailure: forceFailure
        ))
    }

    private func readAll(_ reader: FFMpegFileReader) -> (frames: [MediaTestSupport.DecodedFrame], failed: Bool) {
        var frames: [MediaTestSupport.DecodedFrame] = []
        while true {
            switch reader.readFrame() {
            case let .frame(frame):
                frames.append(MediaTestSupport.frame(frame))
            case .endOfStream:
                return (frames, false)
            case .waitingForMoreData, .error:
                return (frames, true)
            }
        }
    }

    func testFailedHardwareSetupDecodesInSoftware() throws {
        for name in ["h264_bframes", "h264_709", "hevc_bframes"] {
            let path = try MediaTestSupport.resourcePath(name, "mp4")
            let software = readAll(try makeReader(path: path, hardware: false, forceFailure: false))
            XCTAssertFalse(software.failed, name)
            XCTAssertGreaterThan(software.frames.count, 10, name)

            let fallback = readAll(try makeReader(path: path, hardware: true, forceFailure: true))
            XCTAssertFalse(fallback.failed, "\(name): decoding failed after the hardware setup failed")
            XCTAssertEqual(fallback.frames.count, software.frames.count, name)
            XCTAssertTrue(fallback.frames == software.frames, "\(name): fallback frames differ from software frames")
        }
    }
}
