import Foundation
import CoreMedia
import CoreVideo
import XCTest
import SwiftSignalKit
import UniversalMediaPlayer
import FFMpegBinding
import VP9Hardware
@testable import AnimatedStickerNode

private func fixturePath(_ name: String, _ type: String) -> String? {
    let bundles = [Bundle(for: VideoStickerHardwareSelectionTests.self), Bundle.main] + Bundle.allBundles
    return bundles.lazy.compactMap({ $0.path(forResource: name, ofType: type) }).first
}

func copyPlane(from source: UnsafeMutablePointer<UInt8>, stride: Int, to destination: CVPixelBuffer, plane: Int, rowBytes: Int, rows: Int) -> Bool {
    guard let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
        return false
    }
    let dstStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
    for row in 0 ..< rows {
        memcpy(dst.advanced(by: row * dstStride), source.advanced(by: row * stride), rowBytes)
    }
    return true
}

// Where two runs of frames first differ, for the failure message.
private func firstDifference(_ actual: [[Data]], _ expected: [[Data]]) -> String {
    for loop in 0 ..< min(actual.count, expected.count) {
        for frame in 0 ..< min(actual[loop].count, expected[loop].count) {
            let a = actual[loop][frame], e = expected[loop][frame]
            if a == e {
                continue
            }
            if a.count != e.count {
                return "loop \(loop) frame \(frame): \(a.count) bytes vs \(e.count)"
            }
            var count = 0, maxDifference = 0, first = -1
            for i in 0 ..< a.count where a[i] != e[i] {
                count += 1
                maxDifference = max(maxDifference, abs(Int(a[i]) - Int(e[i])))
                if first < 0 {
                    first = i
                }
            }
            return "loop \(loop) frame \(frame): \(count) bytes differ, max \(maxDifference), first at \(first)"
        }
    }
    return actual.map(\.count) == expected.map(\.count) ? "none" : "frame counts differ"
}

// libvpx through FFmpeg, giving the decoded planes as they are (FFMpegFileReader's tri-planar
// output premultiplies luma, which VideoToolbox does not).
final class RawLibvpxReader {
    private let format = FFMpegAVFormatContext()
    private let codecContext: FFMpegAVCodecContext
    private let streamIndex: Int32
    private var sentEnd = false

    init?(path: String) {
        FFMpegGlobals.initializeGlobals()
        guard self.format.openInput(withDirectFilePath: path), self.format.findStreamInfo() else {
            return nil
        }
        guard let index = self.format.streamIndices(for: FFMpegAVFormatStreamTypeVideo).first?.int32Value else {
            return nil
        }
        guard let codec = FFMpegAVCodec.find(forId: self.format.codecId(atStreamIndex: index), preferHardwareAccelerationCapable: false) else {
            return nil
        }
        self.streamIndex = index
        // Probing the file can consume the first (key) frame's packet; start from it again.
        self.format.seekFrame(forStreamIndex: index, pts: 0, positionOnKeyframe: true)
        self.codecContext = FFMpegAVCodecContext(codec: codec)
        guard self.format.codecParams(atStreamIndex: index, to: self.codecContext), self.codecContext.open() else {
            return nil
        }
    }

    func next() -> FFMpegAVFrame? {
        while true {
            let frame = FFMpegAVFrame()
            switch self.codecContext.receive(into: frame) {
            case .success:
                return frame
            case .error:
                return nil
            case .notEnoughData:
                break
            @unknown default:
                return nil
            }
            if self.sentEnd {
                return nil
            }
            let packet = FFMpegPacket()
            if self.format.readFrame(into: packet) {
                if packet.streamIndex == self.streamIndex {
                    let _ = packet.send(toDecoder: self.codecContext)
                }
            } else {
                self.sentEnd = true
                let _ = self.codecContext.sendEnd()
            }
        }
    }
}

// Stands in for the hardware decoder in the simulator (which has none): it returns libvpx's own
// planes as 420v colour and alpha buffers, which is what VideoToolbox returns (the host test
// checks that the planes are identical). It can fail at a given frame.
final class LibvpxBackedDecoder: VideoStickerHardwareDecoder {
    private let path: String
    private var reader: RawLibvpxReader?
    private let failAt: Int?
    private(set) var decodedCount = 0
    private(set) var failure: String?
    private(set) var invalidated = false

    init(path: String, failAt: Int?) {
        self.path = path
        self.failAt = failAt
        self.reset()
    }

    func decode(_ frame: WebMStickerFrame) -> VP9DecodedFrame? {
        if let failAt = self.failAt, self.decodedCount == failAt {
            return nil
        }
        guard let decoded = self.reader?.next() else {
            self.failure = "no frame after \(self.decodedCount)"
            return nil
        }
        guard decoded.pixelFormat == .YUVA else {
            self.failure = "pixel format \(decoded.pixelFormat.rawValue)"
            return nil
        }
        let width = Int(decoded.width)
        let height = Int(decoded.height)
        guard let yPlane = decoded.data[0], let cbPlane = decoded.data[1], let crPlane = decoded.data[2], let aPlane = decoded.data[3] else {
            return nil
        }
        var color: CVPixelBuffer?
        var alpha: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &color)
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &alpha)
        guard let color, let alpha else {
            return nil
        }
        CVPixelBufferLockBaseAddress(color, [])
        CVPixelBufferLockBaseAddress(alpha, [])
        var copied = copyPlane(from: yPlane, stride: Int(decoded.lineSize[0]), to: color, plane: 0, rowBytes: width, rows: height)
            && copyPlane(from: aPlane, stride: Int(decoded.lineSize[3]), to: alpha, plane: 0, rowBytes: width, rows: height)
        if copied, let cbcr = CVPixelBufferGetBaseAddressOfPlane(color, 1)?.assumingMemoryBound(to: UInt8.self) {
            let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(color, 1)
            let cbStride = Int(decoded.lineSize[1]), crStride = Int(decoded.lineSize[2])
            for row in 0 ..< (height + 1) / 2 {
                for column in 0 ..< (width + 1) / 2 {
                    cbcr[row * cbcrStride + column * 2] = cbPlane[row * cbStride + column]
                    cbcr[row * cbcrStride + column * 2 + 1] = crPlane[row * crStride + column]
                }
            }
        } else {
            copied = false
        }
        CVPixelBufferUnlockBaseAddress(alpha, [])
        CVPixelBufferUnlockBaseAddress(color, [])
        if !copied {
            return nil
        }
        self.decodedCount += 1
        return VP9DecodedFrame(color: color, alpha: alpha)
    }

    func reset() {
        self.reader = RawLibvpxReader(path: self.path)
    }

    func invalidate() {
        self.invalidated = true
    }
}

final class VideoStickerHardwareSelectionTests: XCTestCase {
    private let queue = Queue(name: "VideoStickerHardwareSelectionTests")
    private var savedFactory: ((String) -> VideoStickerHardwareStream?)?

    override func setUp() {
        super.setUp()
        installTestLogger
        self.savedFactory = makeVideoStickerHardwareStream
    }

    override func tearDown() {
        if let savedFactory = self.savedFactory {
            makeVideoStickerHardwareStream = savedFactory
        }
        super.tearDown()
    }

    // Queue.sync returns nothing; this returns the closure's result.
    private func onQueue<T>(_ f: () -> T) -> T {
        var result: T?
        self.queue.sync {
            result = f()
        }
        return result!
    }

    private func readLoops(_ source: VideoStickerDirectFrameSource, loops: Int) -> [[Data]] {
        var result: [[Data]] = []
        for _ in 0 ..< loops {
            var frames: [Data] = []
            while frames.count < 1000, let frame = source.takeFrame(draw: true) {
                frames.append(frame.data)
            }
            result.append(frames)
        }
        return result
    }

    private func libvpxFrames(path: String, loops: Int) -> [[Data]] {
        makeVideoStickerHardwareStream = { _, _ in nil }
        return self.onQueue {
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 160, height: 160, cachePathPrefix: nil, unpremultiplyAlpha: false) else {
                return []
            }
            XCTAssertFalse(source.usesHardwareDecoderForTesting)
            return self.readLoops(source, loops: loops)
        }
    }

    // The simulator has no hardware VP9 decoder: the probe says so and libvpx is used.
    func testSimulatorProbeKeepsLibvpx() throws {
        let path = try XCTUnwrap(fixturePath("sticker_vp9", "webm"))
        XCTAssertFalse(videoStickerVP9HardwareProbe.hasHardwareDecoder, "\(videoStickerVP9HardwareProbe)")
        XCTAssertNil(makeVideoStickerHardwareStream(path, false))
        self.queue.sync {
            let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 64, height: 64, cachePathPrefix: nil, unpremultiplyAlpha: false)
            XCTAssertEqual(source?.usesHardwareDecoderForTesting, false)
        }
    }

    // Frames from the hardware path are converted and scaled exactly like libvpx frames.
    func testHardwarePathGivesTheSameFrames() throws {
        let path = try XCTUnwrap(fixturePath("sticker_vp9", "webm"))
        let expected = self.libvpxFrames(path: path, loops: 2)
        XCTAssertEqual(expected.first?.count, 24)

        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        var decoder: LibvpxBackedDecoder?
        makeVideoStickerHardwareStream = { path, _ in
            let instance = LibvpxBackedDecoder(path: path, failAt: nil)
            decoder = instance
            return VideoStickerHardwareStream(frames: sticker.frames, decoder: instance)
        }
        let actual: [[Data]] = self.onQueue {
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 160, height: 160, cachePathPrefix: nil, unpremultiplyAlpha: false) else {
                return []
            }
            XCTAssertTrue(source.usesHardwareDecoderForTesting)
            let frames = self.readLoops(source, loops: 2)
            XCTAssertTrue(source.usesHardwareDecoderForTesting)
            XCTAssertEqual(source.frameCount, 24)
            return frames
        }
        XCTAssertNotNil(decoder)
        XCTAssertNil(decoder?.failure)
        XCTAssertEqual(decoder?.decodedCount, 48)
        XCTAssertEqual(actual.map(\.count), expected.map(\.count))
        XCTAssertEqual(firstDifference(actual, expected), "none", "hardware path frames differ from libvpx frames")
    }

    // A hardware error in the middle of a loop switches to libvpx at the same frame.
    func testHardwareFailureFallsBackToLibvpx() throws {
        let path = try XCTUnwrap(fixturePath("sticker_vp9", "webm"))
        let expected = self.libvpxFrames(path: path, loops: 2)

        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        var decoder: LibvpxBackedDecoder?
        makeVideoStickerHardwareStream = { path, _ in
            let instance = LibvpxBackedDecoder(path: path, failAt: 7)
            decoder = instance
            return VideoStickerHardwareStream(frames: sticker.frames, decoder: instance)
        }
        let actual: [[Data]] = self.onQueue {
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 160, height: 160, cachePathPrefix: nil, unpremultiplyAlpha: false) else {
                return []
            }
            let frames = self.readLoops(source, loops: 2)
            XCTAssertFalse(source.usesHardwareDecoderForTesting)
            return frames
        }
        XCTAssertEqual(decoder?.invalidated, true)
        XCTAssertEqual(actual.map(\.count), expected.map(\.count))
        XCTAssertEqual(firstDifference(actual, expected), "none", "frames after the fallback differ from libvpx frames")
    }

    // A sticker that is hidden gives its hardware sessions back (they are a small, shared resource) and
    // continues from the same frame when it is shown again.
    func testSuspendedHardwareDecodingReleasesTheDecoderAndResumesAtTheSameFrame() throws {
        let path = try XCTUnwrap(fixturePath("sticker_vp9", "webm"))
        let expected = self.libvpxFrames(path: path, loops: 2)

        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        var decoders: [LibvpxBackedDecoder] = []
        makeVideoStickerHardwareStream = { path, _ in
            let instance = LibvpxBackedDecoder(path: path, failAt: nil)
            decoders.append(instance)
            return VideoStickerHardwareStream(frames: sticker.frames, decoder: instance)
        }
        let actual: [[Data]] = self.onQueue {
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 160, height: 160, cachePathPrefix: nil, unpremultiplyAlpha: false) else {
                return []
            }
            var first: [Data] = []
            for _ in 0 ..< 10 {
                if let frame = source.takeFrame(draw: true) {
                    first.append(frame.data)
                }
            }
            source.suspendHardwareDecoding()
            XCTAssertFalse(source.usesHardwareDecoderForTesting)
            XCTAssertEqual(decoders.count, 1)
            XCTAssertEqual(decoders.first?.invalidated, true)
            // Suspending again, or without a hardware decoder, does nothing.
            source.suspendHardwareDecoding()

            var rest: [Data] = []
            while rest.count < 1000, let frame = source.takeFrame(draw: true) {
                rest.append(frame.data)
            }
            XCTAssertTrue(source.usesHardwareDecoderForTesting)
            XCTAssertEqual(decoders.count, 2)
            let second = self.readLoops(source, loops: 1)
            return [first + rest] + second
        }
        XCTAssertEqual(actual.map(\.count), expected.map(\.count))
        XCTAssertEqual(firstDifference(actual, expected), "none", "frames after resuming differ from libvpx frames")
    }

    // Once the frame cache holds the whole sticker, every later frame comes from the cache, and an idle decoder
    // would keep two of the eight shared sessions for as long as the sticker lives: it gives them back at the end
    // of the first loop.
    func testACompleteFrameCacheGivesTheHardwareSessionsBack() throws {
        let path = try XCTUnwrap(fixturePath("sticker_vp9", "webm"))
        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        var decoders: [LibvpxBackedDecoder] = []
        makeVideoStickerHardwareStream = { path, _ in
            let instance = LibvpxBackedDecoder(path: path, failAt: nil)
            decoders.append(instance)
            return VideoStickerHardwareStream(frames: sticker.frames, decoder: instance)
        }
        let directory = NSTemporaryDirectory() + "VideoStickerCache-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            let _ = try? FileManager.default.removeItem(atPath: directory)
        }

        let result: (usedHardware: Bool, usesHardwareAfterTheLoop: Bool, frameCount: Int) = self.onQueue {
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 160, height: 160, cachePathPrefix: directory + "/sticker", unpremultiplyAlpha: false) else {
                return (false, true, 0)
            }
            let usedHardware = source.usesHardwareDecoderForTesting
            var taken = 0
            while taken < 1000, source.frameCount == 0 {
                let _ = source.takeFrame(draw: true)
                taken += 1
            }
            return (usedHardware, source.usesHardwareDecoderForTesting, source.frameCount)
        }
        XCTAssertTrue(result.usedHardware)
        XCTAssertGreaterThan(result.frameCount, 0, "the first loop did not complete the frame cache")
        XCTAssertFalse(result.usesHardwareAfterTheLoop)
        XCTAssertEqual(decoders.count, 1)
        XCTAssertEqual(decoders.first?.invalidated, true)
    }

    // When no hardware slot is free on resume, libvpx continues from the same frame.
    func testResumingWithoutAFreeHardwareSlotContinuesWithLibvpx() throws {
        let path = try XCTUnwrap(fixturePath("sticker_vp9", "webm"))
        let expected = self.libvpxFrames(path: path, loops: 2)

        let sticker = try XCTUnwrap(WebMStickerDemuxer.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        var created = 0
        makeVideoStickerHardwareStream = { path, _ in
            created += 1
            if created > 1 {
                return nil
            }
            return VideoStickerHardwareStream(frames: sticker.frames, decoder: LibvpxBackedDecoder(path: path, failAt: nil))
        }
        let actual: [[Data]] = self.onQueue {
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 160, height: 160, cachePathPrefix: nil, unpremultiplyAlpha: false) else {
                return []
            }
            var first: [Data] = []
            for _ in 0 ..< 10 {
                if let frame = source.takeFrame(draw: true) {
                    first.append(frame.data)
                }
            }
            source.suspendHardwareDecoding()
            var rest: [Data] = []
            while rest.count < 1000, let frame = source.takeFrame(draw: true) {
                rest.append(frame.data)
            }
            XCTAssertFalse(source.usesHardwareDecoderForTesting)
            let second = self.readLoops(source, loops: 1)
            return [first + rest] + second
        }
        XCTAssertEqual(actual.map(\.count), expected.map(\.count))
        XCTAssertEqual(firstDifference(actual, expected), "none", "frames after resuming without hardware differ from libvpx frames")
    }

    // A file the WebM reader rejects stays on libvpx.
    func testUnparsableFileStaysOnLibvpx() throws {
        let path = NSTemporaryDirectory() + "/not-webm-\(UUID().uuidString).webm"
        try Data(repeating: 0x1a, count: 1000).write(to: URL(fileURLWithPath: path))
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        XCTAssertNil(WebMStickerDemuxer.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
    }
}
