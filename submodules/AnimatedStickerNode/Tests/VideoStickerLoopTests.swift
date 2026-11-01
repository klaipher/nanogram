import Foundation
import XCTest
import SwiftSignalKit
@testable import AnimatedStickerNode

private func fixturePath(_ name: String, _ type: String) -> String? {
    let bundles = [Bundle(for: VideoStickerLoopTests.self), Bundle.main] + Bundle.allBundles
    return bundles.lazy.compactMap({ $0.path(forResource: name, ofType: type) }).first
}

final class VideoStickerLoopTests: XCTestCase {
    private let queue = Queue(name: "VideoStickerLoopTests")

    override func setUp() {
        super.setUp()
        installTestLogger
    }

    // Reads one loop: frames until takeFrame returns nil at the end of the stream.
    private func readLoop(_ source: VideoStickerDirectFrameSource, limit: Int = 1000) -> [Data] {
        var frames: [Data] = []
        while frames.count < limit, let frame = source.takeFrame(draw: true) {
            frames.append(frame.data)
        }
        return frames
    }

    // A looping sticker without a frame cache (DirectAnimatedStickerNode) plays the same frames
    // every loop, and the file is opened once instead of once per loop.
    func testLoopingWithoutCacheRewindsTheReader() throws {
        let path = try XCTUnwrap(fixturePath("sticker_vp9", "webm"))
        self.queue.sync {
            let opensBefore = videoStickerReaderOpenCount.with { $0 }
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 128, height: 128, cachePathPrefix: nil, unpremultiplyAlpha: false) else {
                XCTFail("no frame source")
                return
            }
            let first = self.readLoop(source)
            let second = self.readLoop(source)
            let third = self.readLoop(source)
            XCTAssertGreaterThan(first.count, 1)
            XCTAssertEqual(source.frameCount, first.count)
            XCTAssertEqual(second.count, first.count)
            XCTAssertEqual(third.count, first.count)
            XCTAssertTrue(second == first, "frames of the second loop differ")
            XCTAssertTrue(third == first, "frames of the third loop differ")
            XCTAssertEqual(videoStickerReaderOpenCount.with { $0 } - opensBefore, 1)
        }
    }

    // cacheVideoAnimation reads a single loop and stops: the end of the stream must not open the file again.
    func testSingleLoopOpensTheFileOnce() throws {
        let path = try XCTUnwrap(fixturePath("sticker_vp9", "webm"))
        self.queue.sync {
            let opensBefore = videoStickerReaderOpenCount.with { $0 }
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 64, height: 64, cachePathPrefix: nil, unpremultiplyAlpha: false) else {
                XCTFail("no frame source")
                return
            }
            let frames = self.readLoop(source)
            XCTAssertGreaterThan(frames.count, 1)
            XCTAssertEqual(videoStickerReaderOpenCount.with { $0 } - opensBefore, 1)
        }
    }

    // A file that is not a video gives no frames and no crash, also when asked again after the end.
    func testUnreadableFileGivesNoFrames() throws {
        let path = NSTemporaryDirectory() + "/not-a-video-\(UUID().uuidString).webm"
        try Data(repeating: 0x42, count: 4096).write(to: URL(fileURLWithPath: path))
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        self.queue.sync {
            guard let source = VideoStickerDirectFrameSource(queue: self.queue, path: path, width: 64, height: 64, cachePathPrefix: nil, unpremultiplyAlpha: false) else {
                return
            }
            XCTAssertEqual(self.readLoop(source).count, 0)
            XCTAssertEqual(self.readLoop(source).count, 0)
        }
    }
}
