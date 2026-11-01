import Foundation
import XCTest
import SwiftSignalKit
import AnimationCache
@testable import DCTAnimationCacheImpl

private typealias Support = DCTAnimationCacheTestSupport

// The media cache cleanup deletes files by modification date, and cache hits never
// rewrote these files, so items in daily use were deleted and converted again.
final class DCTAnimationCacheRetentionTests: XCTestCase {
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

    private func setModificationDate(_ path: String, secondsAgo: Int) {
        let date = Int(Date().timeIntervalSince1970) - secondsAgo
        var times = [timeval(tv_sec: date, tv_usec: 0), timeval(tv_sec: date, tv_usec: 0)]
        XCTAssertEqual(utimes(path, &times), 0)
    }

    private func modificationAge(_ path: String) -> Int {
        var value = stat()
        XCTAssertEqual(stat(path, &value), 0)
        return Int(Date().timeIntervalSince1970) - Int(value.st_mtimespec.tv_sec)
    }

    func testCacheHitRefreshesStaleModificationDate() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        let path = try Support.installFixture("emoji62_v6", basePath: self.basePath, sourceId: "item", width: 62, height: 62)
        self.setModificationDate(path, secondsAgo: 10 * 24 * 60 * 60)

        XCTAssertNotNil(Support.getItem(cache: cache, sourceId: "item", width: 62, height: 62, fetch: Support.failingFetch))
        XCTAssertLessThan(self.modificationAge(path), 60)
    }

    func testCacheHitKeepsRecentModificationDate() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        let path = try Support.installFixture("emoji62_v6", basePath: self.basePath, sourceId: "item", width: 62, height: 62)
        // Less than an hour old: no metadata write on every hit.
        self.setModificationDate(path, secondsAgo: 30 * 60)

        XCTAssertNotNil(Support.getItem(cache: cache, sourceId: "item", width: 62, height: 62, fetch: Support.failingFetch))
        let age = self.modificationAge(path)
        XCTAssertGreaterThanOrEqual(age, 30 * 60 - 5)
        XCTAssertLessThanOrEqual(age, 30 * 60 + 60)
    }

    func testFirstFrameHitRefreshesStaleModificationDate() throws {
        let cache = Support.makeCache(basePath: self.basePath)
        let path = try Support.installFixture("emoji62_v6", basePath: self.basePath, sourceId: "item", width: 62, height: 62)
        let firstFramePath = path + "-f"
        try FileManager.default.copyItem(atPath: path, toPath: firstFramePath)
        self.setModificationDate(firstFramePath, secondsAgo: 10 * 24 * 60 * 60)

        XCTAssertNotNil(cache.getFirstFrameSynchronously(sourceId: "item", size: CGSize(width: 62, height: 62)))
        XCTAssertLessThan(self.modificationAge(firstFramePath), 60)

        self.setModificationDate(firstFramePath, secondsAgo: 10 * 24 * 60 * 60)
        let semaphore = DispatchSemaphore(value: 0)
        let disposable = cache.getFirstFrame(queue: Queue(), sourceId: "item", size: CGSize(width: 62, height: 62), fetch: nil, completion: { result in
            if result.isFinal {
                semaphore.signal()
            }
        })
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10.0), .success)
        disposable.dispose()
        XCTAssertLessThan(self.modificationAge(firstFramePath), 60)
    }
}
