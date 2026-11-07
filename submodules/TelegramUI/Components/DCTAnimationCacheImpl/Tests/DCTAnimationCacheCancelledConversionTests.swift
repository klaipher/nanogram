import Foundation
import XCTest
import SwiftSignalKit
import AnimationCache
@testable import DCTAnimationCacheImpl

private typealias Support = DCTAnimationCacheTestSupport

// A conversion whose subscribers are all gone is dropped: its partial file does not stay in the temporary
// directory, and no item is stored from it.
final class DCTAnimationCacheCancelledConversionTests: XCTestCase {
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

    func testACancelledConversionLeavesNoTemporaryFileAndNoItem() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        let started = expectation(description: "first frame written")
        let finished = expectation(description: "conversion finished")
        let proceed = DispatchSemaphore(value: 0)
        let writerBox = Atomic<AnimationCacheItemWriter?>(value: nil)

        let disposable = cache.get(sourceId: "cancelled", size: CGSize(width: 32.0, height: 32.0), fetch: { options in
            let writer = options.writer
            let _ = writerBox.swap(writer)
            writer.queue.async {
                writer.add(with: { surface in
                    memset(surface.argb, 0x7f, surface.length)
                    return 1.0
                }, proposedWidth: 32, proposedHeight: 32, insertKeyframe: true)
                started.fulfill()
                let _ = proceed.wait(timeout: .now() + 10.0)
                writer.finish()
                finished.fulfill()
            }
            return EmptyDisposable
        }).start(next: { _ in })

        wait(for: [started], timeout: 10.0)
        disposable.dispose()

        // The cancellation reaches the writer through the cache queue.
        let deadline = Date().addingTimeInterval(5.0)
        while !(writerBox.with { $0?.isCancelled ?? false }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(writerBox.with { $0?.isCancelled ?? false })

        proceed.signal()
        wait(for: [finished], timeout: 10.0)

        let tempPath = self.basePath + "-temp"
        let settle = Date().addingTimeInterval(2.0)
        var leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tempPath)) ?? []
        while !leftovers.isEmpty && Date() < settle {
            Thread.sleep(forTimeInterval: 0.02)
            leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tempPath)) ?? []
        }
        XCTAssertEqual(leftovers, [])

        let itemPath = Support.itemPath(basePath: self.basePath, sourceId: "cancelled", width: 32, height: 32)
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemPath))
    }
}
