import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

final class MediaBoxReleaseMemoryTests: XCTestCase {
    private let itemCount = 3000

    private func itemId(_ index: Int) -> Data {
        return ("media-release-memory-item-" + String(repeating: "x", count: 64) + "-\(index)").data(using: .utf8) ?? Data()
    }

    private func first<T>(_ signal: Signal<T, NoError>, timeout: Double = 30.0) -> T? {
        let expectation = self.expectation(description: "signal")
        var result: T?
        let disposable = (signal |> take(1)).start(next: { value in
            result = value
            expectation.fulfill()
        })
        self.wait(for: [expectation], timeout: timeout)
        disposable.dispose()
        return result
    }

    private func fill(_ box: StorageBox) {
        var items: [(reference: StorageBox.Reference, id: Data, contentType: UInt8, size: Int64)] = []
        for i in 0 ..< self.itemCount {
            items.append((StorageBox.Reference(peerId: Int64(i % 50 + 1), messageNamespace: 0, messageId: Int32(i + 1)), self.itemId(i), 2, Int64(1000 + i)))
        }
        box.batchAdd(items: items)
    }

    private func readEverything(_ box: StorageBox) -> Int64 {
        let stats = self.first(box.getAllStats())
        return stats?.total.contentTypes.values.reduce(0, { $0 + $1.size }) ?? -1
    }

    private func expectedTotal() -> Int64 {
        return (0 ..< self.itemCount).reduce(Int64(0), { $0 + Int64(1000 + $1) })
    }

    private func assertPageCachesReleased(boxes: [StorageBox], release: () -> Void, file: StaticString = #file, line: UInt = #line) {
        for box in boxes {
            self.fill(box)
            XCTAssertEqual(self.readEverything(box), self.expectedTotal(), file: file, line: line)
        }
        let before = boxes.map { $0.pageCacheMemoryUsed() }
        for value in before {
            XCTAssertGreaterThan(value, 256 * 1024, "the reads should have filled the page cache", file: file, line: line)
        }

        release()

        for (index, box) in boxes.enumerated() {
            let after = box.pageCacheMemoryUsed()
            XCTAssertLessThan(after, before[index] / 4, "storage box \(index): page cache \(before[index]) -> \(after) bytes", file: file, line: line)
            XCTAssertEqual(self.readEverything(box), self.expectedTotal(), "data must still read back", file: file, line: line)
        }
    }

    func testReleasingMediaBoxMemoryEmptiesBothStorageIndexPageCaches() {
        let basePath = NSTemporaryDirectory() + "MediaBoxReleaseMemoryTests-" + UUID().uuidString
        defer {
            let _ = try? FileManager.default.removeItem(atPath: basePath)
        }
        let mediaBox = MediaBox(basePath: basePath, isMainProcess: true)
        self.assertPageCachesReleased(boxes: [mediaBox.storageBox, mediaBox.cacheStorageBox], release: {
            mediaBox.releaseMemory()
        })
    }

    func testClearingPostboxCachesReleasesTheMediaIndexPageCaches() {
        let fixture = PostboxFixture(name: "MediaBoxReleaseMemoryTests")
        defer {
            fixture.close()
        }
        let mediaBox = fixture.postbox.mediaBox
        self.assertPageCachesReleased(boxes: [mediaBox.storageBox, mediaBox.cacheStorageBox], release: {
            fixture.postbox.clearCaches()
        })
    }
}
