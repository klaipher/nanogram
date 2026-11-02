import Foundation
import XCTest
import SwiftSignalKit
import AnimationCache
@testable import DCTAnimationCacheImpl

private typealias Support = DCTAnimationCacheTestSupport

// Each new item's first frame was produced twice: once by the first-frame conversion (`-f`),
// and again on the cache's serial queue after the full conversion, which decoded the new item,
// re-encoded frame 0 and replaced the `-f` file. The second copy is now made only when there is
// no `-f` file, and not on the cache queue.
final class DCTAnimationCacheFirstFrameTests: XCTestCase {
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

    private func inode(_ path: String) -> UInt64? {
        var value = stat()
        if stat(path, &value) != 0 {
            return nil
        }
        return UInt64(value.st_ino)
    }

    private func frames() throws -> [(data: Data, width: Int, height: Int, bytesPerRow: Int, duration: Double)] {
        let cache = Support.makeCache(basePath: self.basePath + "/fixture")
        _ = try Support.installFixture("emoji62_v6", basePath: self.basePath + "/fixture", sourceId: "fixture", width: 62, height: 62)
        let item = try XCTUnwrap(Support.getItem(cache: cache, sourceId: "fixture", width: 62, height: 62, fetch: Support.failingFetch))
        return Support.decodeFrames(item)
    }

    private func writeFirstFrame(cache: AnimationCache, sourceId: String, frames: [(data: Data, width: Int, height: Int, bytesPerRow: Int, duration: Double)]) -> AnimationCacheItem? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: AnimationCacheItem?
        let disposable = cache.getFirstFrame(queue: Queue(), sourceId: sourceId, size: CGSize(width: 62, height: 62), fetch: { options in
            let writer = options.writer
            writer.queue.async {
                let frame = frames[0]
                writer.add(with: { surface in
                    frame.data.withUnsafeBytes { bytes in
                        let source = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        for y in 0 ..< min(surface.height, frame.height) {
                            memcpy(surface.argb.advanced(by: y * surface.bytesPerRow), source.advanced(by: y * frame.bytesPerRow), min(surface.bytesPerRow, frame.bytesPerRow))
                        }
                    }
                    return frame.duration
                }, proposedWidth: 62, proposedHeight: 62, insertKeyframe: true)
                writer.finish()
            }
            return EmptyDisposable
        }, completion: { value in
            if value.isFinal {
                result = value.item
                semaphore.signal()
            }
        })
        XCTAssertEqual(semaphore.wait(timeout: .now() + 30.0), .success)
        disposable.dispose()
        return result
    }

    func testExistingFirstFrameFileIsKept() throws {
        let frames = try self.frames()
        let cache = Support.makeCache(basePath: self.basePath)
        XCTAssertNotNil(self.writeFirstFrame(cache: cache, sourceId: "item", frames: frames))
        let firstFramePath = Support.itemPath(basePath: self.basePath, sourceId: "item", width: 62, height: 62) + "-f"
        let before = try XCTUnwrap(self.inode(firstFramePath))
        let firstFrameBytes = try Data(contentsOf: URL(fileURLWithPath: firstFramePath))

        XCTAssertNotNil(Support.writeFrames(cache: cache, sourceId: "item", width: 62, height: 62, frames: frames))
        XCTAssertEqual(self.inode(firstFramePath), before, "the first-frame file was written again")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: firstFramePath)), firstFrameBytes)
    }

    func testMissingFirstFrameFileIsWrittenFromTheItem() throws {
        let frames = try self.frames()
        let cache = Support.makeCache(basePath: self.basePath)
        XCTAssertNotNil(Support.writeFrames(cache: cache, sourceId: "item", width: 62, height: 62, frames: frames))
        let firstFramePath = Support.itemPath(basePath: self.basePath, sourceId: "item", width: 62, height: 62) + "-f"
        // Written before the item is reported, as before.
        XCTAssertNotNil(self.inode(firstFramePath))
        let firstFrame = try XCTUnwrap(cache.getFirstFrameSynchronously(sourceId: "item", size: CGSize(width: 62, height: 62)))
        XCTAssertEqual(firstFrame.numFrames, 1)
        XCTAssertEqual(Support.decodeFrames(firstFrame).count, 1)
    }

    // A smaller first frame is scaled from a larger one on disk, including one written before this
    // process started (the cache keeps no list across launches).
    func testFirstFrameIsAdaptedFromALargerSizeOnDisk() throws {
        let frames = try self.frames()
        let writerCache = Support.makeCache(basePath: self.basePath)
        XCTAssertNotNil(Support.writeFrames(cache: writerCache, sourceId: "large", width: 62, height: 62, frames: frames))

        // A new cache instance over the same directory, as after a relaunch.
        let cache = Support.makeCache(basePath: self.basePath)
        let adapted = try XCTUnwrap(cache.getFirstFrameSynchronously(sourceId: "large", size: CGSize(width: 32, height: 32)))
        XCTAssertEqual(adapted.numFrames, 1)
        XCTAssertNotNil(self.inode(Support.itemPath(basePath: self.basePath, sourceId: "large", width: 32, height: 32) + "-f"))

        // The directory has been listed now; a later miss in it finds the sizes by stat, and the
        // smallest larger one is used, as before (32 for 16).
        let smaller = try XCTUnwrap(cache.getFirstFrameSynchronously(sourceId: "large", size: CGSize(width: 16, height: 16)))
        XCTAssertEqual(smaller.numFrames, 1)
        XCTAssertNotNil(self.inode(Support.itemPath(basePath: self.basePath, sourceId: "large", width: 16, height: 16) + "-f"))

        // Nothing larger exists for another item.
        XCTAssertNil(cache.getFirstFrameSynchronously(sourceId: "other", size: CGSize(width: 32, height: 32)))
    }
}
