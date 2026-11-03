import Foundation
import XCTest
import SwiftSignalKit
import AnimationCache
@testable import DCTAnimationCacheImpl

private typealias Support = DCTAnimationCacheTestSupport

// A converted item is moved into place and reported to its subscribers. Upstream did this on the
// cache queue right after the conversion finished; it then moved to the conversion's fetch queue,
// where it waited behind every conversion queued there meanwhile (an emoji panel or a reaction
// picker queues dozens, each a few hundred milliseconds): a new reaction or emoji stayed on its
// first frame, or empty, for seconds.
final class DCTAnimationCacheStoreQueueTests: XCTestCase {
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

    private func frames() throws -> [(data: Data, width: Int, height: Int, bytesPerRow: Int, duration: Double)] {
        let cache = Support.makeCache(basePath: self.basePath + "/fixture")
        _ = try Support.installFixture("emoji62_v6", basePath: self.basePath + "/fixture", sourceId: "fixture", width: 62, height: 62)
        let item = try XCTUnwrap(Support.getItem(cache: cache, sourceId: "fixture", width: 62, height: 62, fetch: Support.failingFetch))
        return Support.decodeFrames(item)
    }

    func testFinishedItemIsReportedWhileItsConversionQueueIsBusy() throws {
        let frames = try self.frames()
        let cache = Support.makeCache(basePath: self.basePath)

        // Stands for the next item's conversion, queued on the same fetch queue.
        let releaseNextConversion = DispatchSemaphore(value: 0)
        defer {
            releaseNextConversion.signal()
        }

        let start = CFAbsoluteTimeGetCurrent()
        let item = Support.getItem(cache: cache, sourceId: "item", width: 62, height: 62, timeout: 5.0, fetch: { options in
            let writer = options.writer
            writer.queue.async {
                for frame in frames {
                    writer.add(with: { surface in
                        frame.data.withUnsafeBytes { bytes in
                            let source = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                            for y in 0 ..< min(surface.height, frame.height) {
                                memcpy(surface.argb.advanced(by: y * surface.bytesPerRow), source.advanced(by: y * frame.bytesPerRow), min(surface.bytesPerRow, frame.bytesPerRow))
                            }
                        }
                        return frame.duration
                    }, proposedWidth: 62, proposedHeight: 62, insertKeyframe: false)
                }
                // The native queue: `Queue.async` runs inline on its own queue.
                writer.queue.queue.async {
                    _ = releaseNextConversion.wait(timeout: .now() + 20.0)
                }
                writer.finish()
            }
            return EmptyDisposable
        })
        Support.log(String(format: "STOREQUEUE item reported after %.3f s (nil = not within 5 s)", CFAbsoluteTimeGetCurrent() - start) + " item=\(item != nil)")

        let reported = try XCTUnwrap(item, "the finished item waited for the next conversion on its fetch queue")
        XCTAssertEqual(reported.numFrames, frames.count)
        XCTAssertNotNil(cache.getFirstFrameSynchronously(sourceId: "item", size: CGSize(width: 62, height: 62)))
    }
}
