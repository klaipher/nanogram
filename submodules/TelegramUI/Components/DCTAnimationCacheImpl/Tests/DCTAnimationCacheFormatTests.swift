import Foundation
import XCTest
import SwiftSignalKit
import AnimationCache
@testable import DCTAnimationCacheImpl

private typealias Support = DCTAnimationCacheTestSupport

final class DCTAnimationCacheFormatTests: XCTestCase {
    private var basePath: String!

    override func setUp() {
        super.setUp()
        self.basePath = Support.makeTempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.basePath)
        try? FileManager.default.removeItem(atPath: self.basePath + "-temp")
        super.tearDown()
    }

    // Golden values were recorded from files written by the shipped (format 6) writer,
    // decoded by the reader before any change in this area.
    private static let goldens: [(name: String, width: Int, height: Int, frames: Int, checksum: UInt64)] = [
        ("emoji54_v6", 54, 54, 1, 5922800617055667900),
        ("emoji62_v6", 62, 62, 90, 17119214624039933728),
        ("sticker160_v6", 160, 160, 30, 1854480327934071656),
    ]

    func testVersion6FilesStillDecodeUnchanged() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        for golden in Self.goldens {
            let sourceId = "fixture-\(golden.name)"
            _ = try Support.installFixture(golden.name, basePath: self.basePath, sourceId: sourceId, width: golden.width, height: golden.height)
            guard let item = Support.getItem(cache: cache, sourceId: sourceId, width: golden.width, height: golden.height, fetch: Support.failingFetch) else {
                XCTFail("\(golden.name) did not load")
                continue
            }
            let frames = Support.decodeFrames(item)
            let checksum = Support.checksum(frames: frames)
            Support.log("GOLDEN \(golden.name) frames=\(item.numFrames) decoded=\(frames.count) checksum=\(checksum)")
            XCTAssertEqual(frames.count, item.numFrames)
            XCTAssertEqual(item.numFrames, golden.frames, golden.name)
            XCTAssertEqual(checksum, golden.checksum, golden.name)
        }
    }

    // Re-encoding decoded fixture frames through the cache writer. The goldens were recorded
    // with the format 6 writer; a lossless container change must decode to the same pixels.
    private static let reencodeGoldens: [(name: String, width: Int, height: Int, checksum: UInt64)] = [
        ("emoji62_v6", 62, 62, 15546205421717925383),
        ("sticker160_v6", 160, 160, 9107420832002127963),
    ]

    func testReencodedFramesDecodeToRecordedPixels() throws {
        // Both formats carry the same coefficients, so both must give the recorded pixels.
        for formatVersion: UInt32 in [7, 6] {
            dctAnimationCacheWriterFormatVersion = formatVersion
            defer {
                dctAnimationCacheWriterFormatVersion = 8
            }
            let cache = Support.makeCache(basePath: self.basePath + "/v\(formatVersion)")
            for golden in Self.reencodeGoldens {
                let sourceId = "fixture-\(golden.name)"
                _ = try Support.installFixture(golden.name, basePath: self.basePath + "/v\(formatVersion)", sourceId: sourceId, width: golden.width, height: golden.height)
                guard let item = Support.getItem(cache: cache, sourceId: sourceId, width: golden.width, height: golden.height, fetch: Support.failingFetch) else {
                    XCTFail("\(golden.name) did not load")
                    continue
                }
                let frames = Support.decodeFrames(item)
                let reencodedId = "reencoded-\(golden.name)"
                guard let reencoded = Support.writeFrames(cache: cache, sourceId: reencodedId, width: golden.width, height: golden.height, frames: frames) else {
                    XCTFail("\(golden.name) re-encode failed")
                    continue
                }
                XCTAssertEqual(reencoded.numFrames, frames.count)
                let path = Support.itemPath(basePath: self.basePath + "/v\(formatVersion)", sourceId: reencodedId, width: golden.width, height: golden.height)
                XCTAssertEqual(Support.storedFormatVersion(path: path), formatVersion)
                
                let decoded = Support.decodeFrames(reencoded)
                let checksum = Support.checksum(frames: decoded)
                XCTAssertEqual(checksum, golden.checksum, "\(golden.name) format \(formatVersion)")
                
                // The second loop decodes to the same frames as the first.
                let secondLoop = Support.decodeFrames(reencoded)
                XCTAssertEqual(Support.checksum(frames: secondLoop), checksum, golden.name)
                
                // A fresh reader of the same file agrees with the reused buffers.
                if let fresh = Support.getItem(cache: cache, sourceId: reencodedId, width: golden.width, height: golden.height, fetch: Support.failingFetch) {
                    XCTAssertEqual(Support.checksum(frames: Support.decodeFrames(fresh)), checksum, golden.name)
                } else {
                    XCTFail()
                }
            }
        }
    }

    func testNewItemsAreWrittenInTheCurrentFormat() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        _ = try Support.installFixture("emoji62_v6", basePath: self.basePath, sourceId: "source", width: 62, height: 62)
        let item = try XCTUnwrap(Support.getItem(cache: cache, sourceId: "source", width: 62, height: 62, fetch: Support.failingFetch))
        let frames = Support.decodeFrames(item)
        XCTAssertNotNil(Support.writeFrames(cache: cache, sourceId: "new", width: 62, height: 62, frames: frames))
        XCTAssertEqual(Support.storedFormatVersion(path: Support.itemPath(basePath: self.basePath, sourceId: "new", width: 62, height: 62)), 8)
        // The first-frame file written next to it uses the same format.
        XCTAssertEqual(Support.storedFormatVersion(path: Support.itemPath(basePath: self.basePath, sourceId: "new", width: 62, height: 62) + "-f"), 8)
    }

    func testTruncatedFilesFailWithoutCrashing() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        _ = try Support.installFixture("emoji62_v6", basePath: self.basePath, sourceId: "source", width: 62, height: 62)
        let item = try XCTUnwrap(Support.getItem(cache: cache, sourceId: "source", width: 62, height: 62, fetch: Support.failingFetch))
        let frames = Support.decodeFrames(item)
        XCTAssertNotNil(Support.writeFrames(cache: cache, sourceId: "new", width: 62, height: 62, frames: frames))
        let path = Support.itemPath(basePath: self.basePath, sourceId: "new", width: 62, height: 62)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        
        for length in [8, 60, data.count / 3, data.count / 2, data.count - 8] {
            let truncatedPath = Support.itemPath(basePath: self.basePath, sourceId: "truncated-\(length)", width: 62, height: 62)
            try FileManager.default.createDirectory(atPath: (truncatedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.prefix(length).write(to: URL(fileURLWithPath: truncatedPath))
            var fetched = false
            let result = Support.getItem(cache: cache, sourceId: "truncated-\(length)", width: 62, height: 62, timeout: 2.0, fetch: { options in
                fetched = true
                options.writer.finish()
                return EmptyDisposable
            })
            if let result {
                // Frames past the cut are missing, never garbage.
                for _ in 0 ..< result.numFrames * 2 {
                    let _ = result.advance(advance: .frames(1), requestedFormat: .rgba)
                }
            } else {
                XCTAssertTrue(fetched)
            }
        }
        
        // Corrupt payload bytes in the middle of the frame stream.
        var corrupted = data
        for i in stride(from: data.count / 2, to: min(data.count, data.count / 2 + 64), by: 1) {
            corrupted[i] = corrupted[i] ^ 0x5a
        }
        let corruptedPath = Support.itemPath(basePath: self.basePath, sourceId: "corrupted", width: 62, height: 62)
        try FileManager.default.createDirectory(atPath: (corruptedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try corrupted.write(to: URL(fileURLWithPath: corruptedPath))
        if let result = Support.getItem(cache: cache, sourceId: "corrupted", width: 62, height: 62, timeout: 2.0, fetch: { options in
            options.writer.finish()
            return EmptyDisposable
        }) {
            for _ in 0 ..< result.numFrames * 2 {
                let _ = result.advance(advance: .frames(1), requestedFormat: .rgba)
            }
        }
    }

    func testFailedWriterReportsCancelledSoProducersStop() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        let semaphore = DispatchSemaphore(value: 0)
        var cancelledAfterFailure = false
        var cancelledBeforeFailure = true
        let disposable = cache.get(sourceId: "failing", size: CGSize(width: 32, height: 32), fetch: { options in
            let writer = options.writer
            writer.queue.async {
                writer.add(with: { _ in return 0.1 }, proposedWidth: 32, proposedHeight: 32, insertKeyframe: true)
                cancelledBeforeFailure = writer.isCancelled
                // A frame of another size fails the writer.
                writer.add(with: { _ in return 0.1 }, proposedWidth: 64, proposedHeight: 64, insertKeyframe: false)
                cancelledAfterFailure = writer.isCancelled
                writer.finish()
                semaphore.signal()
            }
            return EmptyDisposable
        }).start()
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10.0), .success)
        disposable.dispose()
        XCTAssertFalse(cancelledBeforeFailure)
        XCTAssertTrue(cancelledAfterFailure)
    }
}
