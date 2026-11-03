import XCTest
import CoreMedia
import FFMpegBinding
@testable import TelegramMediaPlayer

// avformat_find_stream_info used to decode frames of every opened file in software: up to 7 H.264
// frames to guess the reorder delay, one VP9/HEVC frame to learn the pixel format. The players
// decode from frame 0 with their own decoder afterwards, so this was thrown away (about 1.7 s CPU
// in a 7-minute device session). A stream is now left undecoded when the container header already
// gives its size and reorder delay. These tests pin that the output is the same as with the full
// probe, and which files keep it.
final class FFMpegStreamInfoProbeTests: XCTestCase {
    // name, extension, video streams whose probe decoding is skipped
    private let fixtures: [(String, String, Int)] = [
        ("h264_bframes", "mp4", 1), // B-frames: mov derives the delay from the ctts box
        ("h264_bframes_editlist", "mp4", 1), // starts mid-GOP through an edit list
        ("aac_h264_bframes", "mp4", 1), // audio track first; the AAC stream is still probed
        ("h264_709", "mp4", 1),
        ("hevc_bframes", "mp4", 1), // HEVC signals the reorder depth in its SPS
        ("sticker_vp9", "webm", 1), // VP9 with alpha, as video stickers are
        ("h264_bframes_cmaf", "mp4", 0), // fragmented: no ctts in moov and no SPS restriction
        ("h264_noreorder", "mp4", 0) // no ctts, POC type 0, no SPS restriction: unknown, so probed
    ]

    private func makeReader(path: String, mediaType: FFMpegFileReader.SelectedStream.MediaType = .video, fullProbe: Bool, skipLoopFilter: Bool = false) throws -> FFMpegFileReader {
        return try XCTUnwrap(FFMpegFileReader(
            source: .file(path),
            passthroughDecoder: false,
            useHardwareAcceleration: false,
            skipLoopFilter: skipLoopFilter,
            selectedStream: .mediaType(mediaType),
            seek: nil,
            maxReadablePts: nil,
            ignoreEditList: false,
            fullStreamInfoProbe: fullProbe
        ), "cannot open \(path)")
    }

    func testProbeSkipsDecodingOnlyWhenTheHeaderDescribesTheStream() throws {
        for (name, ext, expected) in fixtures {
            let path = try MediaTestSupport.resourcePath(name, ext)
            XCTAssertEqual(try makeReader(path: path, fullProbe: false).streamInfoProbeSkippedStreamCount, expected, name)
            XCTAssertEqual(try makeReader(path: path, fullProbe: true).streamInfoProbeSkippedStreamCount, 0, name)
        }
    }

    func testFramesMatchFullProbe() throws {
        for (name, ext, _) in fixtures {
            let path = try MediaTestSupport.resourcePath(name, ext)
            let argbModes: [Bool] = ext == "webm" ? [false, true] : [false]
            for argb in argbModes {
                for skipLoopFilter in [false, true] {
                    let reference = MediaTestSupport.readFrames(try makeReader(path: path, fullProbe: true, skipLoopFilter: skipLoopFilter), argb: argb)
                    let frames = MediaTestSupport.readFrames(try makeReader(path: path, fullProbe: false, skipLoopFilter: skipLoopFilter), argb: argb)
                    XCTAssertGreaterThan(reference.count, 10, name)
                    XCTAssertEqual(frames.count, reference.count, "\(name): frame count")
                    for i in 0 ..< min(frames.count, reference.count) {
                        XCTAssertEqual(frames[i].pts, reference[i].pts, "\(name) frame \(i): pts")
                        XCTAssertTrue(frames[i].bytes == reference[i].bytes, "\(name) frame \(i): pixels differ (argb \(argb))")
                    }
                }
            }
        }
    }

    func testAudioMatchesFullProbe() throws {
        let path = try MediaTestSupport.resourcePath("aac_h264_bframes", "mp4")
        let reference = MediaTestSupport.readFrames(try makeReader(path: path, mediaType: .audio, fullProbe: true))
        let frames = MediaTestSupport.readFrames(try makeReader(path: path, mediaType: .audio, fullProbe: false))
        XCTAssertGreaterThan(reference.count, 10)
        XCTAssertEqual(frames, reference)
    }

    // What the players read from the format context after the probe.
    func testStreamParametersMatchFullProbe() throws {
        for (name, ext, _) in fixtures {
            let path = try MediaTestSupport.resourcePath(name, ext)
            var described: [String] = []
            for fullProbe in [true, false] {
                let context = FFMpegAVFormatContext()
                XCTAssertTrue(context.openInput(withDirectFilePath: path), name)
                XCTAssertTrue(context.findStreamInfo(withFullProbe: fullProbe), name)
                var lines: [String] = ["duration \(context.duration())"]
                for type in [FFMpegAVFormatStreamTypeVideo, FFMpegAVFormatStreamTypeAudio] {
                    for indexNumber in context.streamIndices(for: type) {
                        let index = indexNumber.int32Value
                        let fpsAndTimebase = context.fpsAndTimebase(forStreamIndex: index, defaultTimeBase: CMTimeMake(value: 1, timescale: 40000))
                        let metrics = context.metricsForStream(at: index)
                        lines.append("stream \(index) codec \(context.codecId(atStreamIndex: index)) fps \(fpsAndTimebase.fps.value)/\(fpsAndTimebase.fps.timescale) timebase \(fpsAndTimebase.timebase.value)/\(fpsAndTimebase.timebase.timescale) start \(context.startTime(atStreamIndex: index)) duration \(context.duration(atStreamIndex: index)) size \(metrics.width)x\(metrics.height) rotation \(metrics.rotationAngle) extradata \(metrics.extradataSize) attachedPic \(context.isAttachedPic(atStreamIndex: index)) index \(context.numberOfIndexEntries(atStreamIndex: index))")
                    }
                }
                described.append(lines.joined(separator: "\n"))
            }
            XCTAssertEqual(described[1], described[0], name)
        }
    }

    // H.264 SPS parsing that decides whether the delay is known. The x264 SPS (High, 640x360,
    // bitstream_restriction with num_reorder_frames 2) and the POC type 2 SPS were checked against
    // FFmpeg's own parser, as was the parser itself on 50,000 random SPSs.
    func testAvcCReorderDelaySignalling() throws {
        func data(_ hex: String) -> Data {
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index ..< next], radix: 16) ?? 0) // swiftlint:disable:this narrowing_integer_conversion
                index = next
            }
            return Data(bytes)
        }
        let x264 = data("0164001effe100196764001eacd940a02ff9610000030001000003003c0f162d9601000668ebe3cb22c0")
        let pocType2 = data("0142c01effe100086742c01eda0404e401000668ebe3cb22c0")
        XCTAssertTrue(FFMpegAVFormatContext.avcCSignalsReorderDelay(x264))
        XCTAssertTrue(FFMpegAVFormatContext.avcCSignalsReorderDelay(pocType2))

        // Apple's encoder: POC type 0 and no restriction.
        let context = FFMpegAVFormatContext()
        XCTAssertTrue(context.openInput(withDirectFilePath: try MediaTestSupport.resourcePath("h264_noreorder", "mp4")))
        let metrics = context.metricsForStream(at: 0)
        let extradata: UnsafeMutablePointer<UInt8> = try XCTUnwrap(metrics.extradata)
        let apple = Data(bytes: extradata, count: Int(metrics.extradataSize))
        XCTAssertFalse(FFMpegAVFormatContext.avcCSignalsReorderDelay(apple))

        // Anything cut short or malformed is "unknown".
        XCTAssertFalse(FFMpegAVFormatContext.avcCSignalsReorderDelay(Data()))
        // The SPS ends at byte 33 of the record.
        for length in 0 ..< 33 {
            XCTAssertFalse(FFMpegAVFormatContext.avcCSignalsReorderDelay(x264.prefix(length)), "record truncated to \(length) bytes")
        }
        var notAvcC = x264
        notAvcC[0] = 0
        XCTAssertFalse(FFMpegAVFormatContext.avcCSignalsReorderDelay(notAvcC))
        var notSps = x264
        notSps[8] = 0x68
        XCTAssertFalse(FFMpegAVFormatContext.avcCSignalsReorderDelay(notSps))
        var oversizedLength = x264
        oversizedLength[6] = 0xff
        XCTAssertFalse(FFMpegAVFormatContext.avcCSignalsReorderDelay(oversizedLength))
    }

    // Not an assertion on speed (the simulator is noisy): prints the open cost both ways.
    func testOpenCost() throws {
        var inputs: [(String, String)] = []
        for (name, ext, _) in fixtures {
            inputs.append((name, try MediaTestSupport.resourcePath(name, ext)))
        }
        // Uneven frame durations: FFmpeg reads 20 packets to estimate the rate, decoding 7 of them.
        inputs.append(("640x360 b-frames vfr", try MediaTestSupport.makeClip(width: 640, height: 360, frameCount: 90, frameReordering: true, variableFrameDurations: true, color709: false)))
        inputs.append(("1280x720 b-frames vfr", try MediaTestSupport.makeClip(width: 1280, height: 720, frameCount: 60, frameReordering: true, variableFrameDurations: true, color709: false)))
        for (name, path) in inputs {
            var best: [Bool: Double] = [:]
            var skipped = 0
            for _ in 0 ..< 7 {
                for fullProbe in [true, false] {
                    let start = CFAbsoluteTimeGetCurrent()
                    let reader = try makeReader(path: path, fullProbe: fullProbe)
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    if !fullProbe {
                        skipped = reader.streamInfoProbeSkippedStreamCount
                    }
                    best[fullProbe] = min(best[fullProbe] ?? .infinity, elapsed)
                }
            }
            let full = (best[true] ?? 0.0) * 1000.0
            let now = (best[false] ?? 0.0) * 1000.0
            print("FFMpegStreamInfoProbe open \(name): \(String(format: "%.3f", full)) ms with the full probe, \(String(format: "%.3f", now)) ms now (skipped \(skipped))")
        }
    }

    func testStickerSourceSkipsTheProbeDecode() throws {
        let path = try MediaTestSupport.resourcePath("sticker_vp9", "webm")
        let source = SoftwareVideoSource(path: path, hintVP9: true, unpremultiplyAlpha: true)
        XCTAssertTrue(source.hasStream)
        XCTAssertEqual(source.streamInfoProbeSkippedStreamCount, 1)
        var frames = 0
        for _ in 0 ..< 200 {
            let (frame, _, _, loop) = source.readFrame(maxPts: nil)
            if frame != nil {
                frames += 1
            }
            if loop {
                break
            }
        }
        XCTAssertGreaterThan(frames, 10)
    }
}
