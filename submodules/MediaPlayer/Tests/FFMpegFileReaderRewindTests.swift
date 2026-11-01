import XCTest
import CoreMedia
@testable import UniversalMediaPlayer

// Looping GIF tiles (BatchVideoRenderingContext) rebuilt their FFMpegFileReader at every end of
// stream: file open, header parse, stream probe and codec setup on each loop. They now rewind the
// reader. These tests pin that a rewound reader replays exactly what a new reader produces.
final class FFMpegFileReaderRewindTests: XCTestCase {
    private let fixtures: [(String, String)] = [
        ("h264_bframes", "mp4"),
        ("h264_bframes_editlist", "mp4"),
        ("h264_noreorder", "mp4"),
        ("h264_bframes_cmaf", "mp4"),
        ("hevc_bframes", "mp4"),
        ("sticker_vp9", "webm")
    ]

    // The GIF grid's reader configuration.
    private func makeGifReader(path: String, passthrough: Bool = false) throws -> FFMpegFileReader {
        return try XCTUnwrap(FFMpegFileReader(
            source: .file(path),
            passthroughDecoder: passthrough,
            useHardwareAcceleration: false,
            skipLoopFilter: !passthrough,
            selectedStream: .mediaType(.video),
            seek: nil,
            maxReadablePts: nil
        ))
    }

    func testRewindAtEndReplaysTheSameFrames() throws {
        for (name, ext) in fixtures {
            let path = try MediaTestSupport.resourcePath(name, ext)
            let reference = MediaTestSupport.readFrames(try makeGifReader(path: path))
            XCTAssertGreaterThan(reference.count, 10, name)

            let reader = try makeGifReader(path: path)
            XCTAssertEqual(MediaTestSupport.readFrames(reader), reference, "\(name): first pass")
            for loop in 1 ... 3 {
                XCTAssertTrue(reader.rewind(), "\(name): rewind \(loop)")
                let frames = MediaTestSupport.readFrames(reader)
                XCTAssertEqual(frames.count, reference.count, "\(name) loop \(loop): frame count")
                XCTAssertTrue(frames == reference, "\(name) loop \(loop): frames differ from a new reader")
            }
        }
    }

    func testRewindMidStreamStartsOver() throws {
        for (name, ext) in fixtures {
            let path = try MediaTestSupport.resourcePath(name, ext)
            let reference = MediaTestSupport.readFrames(try makeGifReader(path: path))
            let reader = try makeGifReader(path: path)
            let _ = MediaTestSupport.readFrames(reader, maxFrames: 7)
            XCTAssertTrue(reader.rewind(), name)
            XCTAssertTrue(MediaTestSupport.readFrames(reader) == reference, "\(name): frames after a mid-stream rewind")
        }
    }

    // The grid's fallback for formats FFmpeg cannot decode here does not rewind; it is rebuilt.
    func testPassthroughReaderDoesNotRewind() throws {
        let reader = try makeGifReader(path: try MediaTestSupport.resourcePath("h264_bframes", "mp4"), passthrough: true)
        let _ = MediaTestSupport.readFrames(reader)
        XCTAssertFalse(reader.rewind())
    }

    // Not an assertion on speed: prints the cost of a loop restart both ways.
    func testLoopRestartCost() throws {
        for (name, ext) in fixtures {
            let path = try MediaTestSupport.resourcePath(name, ext)
            let reader = try makeGifReader(path: path)
            let iterations = 20
            var start = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< iterations {
                let fresh = try makeGifReader(path: path)
                if case .frame = fresh.readFrame() {
                } else {
                    XCTFail(name)
                }
            }
            let rebuild = CFAbsoluteTimeGetCurrent() - start
            start = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< iterations {
                XCTAssertTrue(reader.rewind())
                if case .frame = reader.readFrame() {
                } else {
                    XCTFail(name)
                }
            }
            let rewind = CFAbsoluteTimeGetCurrent() - start
            print("FFMpegFileReaderRewind \(name): first frame after a loop \(String(format: "%.3f", rebuild * 1000.0 / Double(iterations))) ms with a new reader, \(String(format: "%.3f", rewind * 1000.0 / Double(iterations))) ms after rewind")
        }
    }
}
