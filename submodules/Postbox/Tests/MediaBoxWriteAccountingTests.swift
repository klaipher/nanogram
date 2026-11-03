import Foundation
import XCTest
import SwiftSignalKit
import DiskWriteAccounting
@testable import Postbox

/// MediaBox and SQLite count what they write (DiskWriteAccounting), by media type and by database, so a MetricKit
/// disk-write report can be matched to its writers. Also: a resource that is only looked at (its status shown, never
/// downloaded) writes nothing; it used to write an empty `<id>_partial.meta` map the moment its file context opened
/// (MetricKit 2026-11-02, 4 of 101 disk-write samples).
final class MediaBoxWriteAccountingTests: XCTestCase {
    private final class TestResource: MediaResource {
        let id: MediaResourceId
        let size: Int64?

        init(_ id: String, size: Int64?) {
            self.id = MediaResourceId(id)
            self.size = size
        }

        var streamable: Bool {
            return true
        }

        var headerSize: Int32 {
            return 0
        }

        func isEqual(to: MediaResource) -> Bool {
            return (to as? TestResource)?.id == self.id
        }
    }

    private static let tempBoxInitialized: Bool = {
        TempBox.initializeShared(basePath: NSTemporaryDirectory() + "MediaBoxWriteAccountingTests-TempBox", processType: "tests", launchSpecificId: Int64(Date().timeIntervalSince1970 * 1000))
        return true
    }()

    private var basePath: String!
    private var mediaBox: MediaBox!

    override func setUp() {
        super.setUp()
        XCTAssertTrue(MediaBoxWriteAccountingTests.tempBoxInitialized)
        self.basePath = NSTemporaryDirectory() + "MediaBoxWriteAccountingTests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
        self.mediaBox = MediaBox(basePath: self.basePath, isMainProcess: false)
    }

    override func tearDown() {
        self.mediaBox.dataQueue.sync {}
        for storageBox in [self.mediaBox.storageBox, self.mediaBox.cacheStorageBox] {
            let semaphore = DispatchSemaphore(value: 0)
            let disposable = storageBox.get(ids: []).start(completed: {
                semaphore.signal()
            })
            let _ = semaphore.wait(timeout: .now() + 10.0)
            disposable.dispose()
        }
        self.mediaBox = nil
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func payload(_ count: Int) -> Data {
        return Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    }

    /// A fetcher that serves `data` in parts of `partSize` bytes for whatever ranges are asked.
    private func installFetcher(data: Data, partSize: Int) {
        self.mediaBox.fetchResource = { _, ranges, _ in
            return ranges
            |> castError(MediaResourceDataFetchError.self)
            |> take(1)
            |> mapToSignal { ranges -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> in
                return Signal { subscriber in
                    for (range, _) in ranges {
                        var offset = Int(range.lowerBound)
                        while offset < min(Int(range.upperBound), data.count) {
                            let end = min(offset + partSize, data.count)
                            subscriber.putNext(.dataPart(resourceOffset: Int64(offset), data: data.subdata(in: offset ..< end), range: 0 ..< Int64(end - offset), complete: end == data.count))
                            offset = end
                        }
                    }
                    return EmptyDisposable
                }
            }
        }
    }

    private func fetchRange(_ resource: TestResource, _ range: Range<Int64>, contentType: UInt8) {
        let parameters = MediaResourceFetchParameters(tag: nil, info: nil, location: nil, contentType: contentType, isRandomAccessAllowed: true)
        let done = self.expectation(description: "fetched")
        done.assertForOverFulfill = false
        let disposable = self.mediaBox.fetchedResourceData(resource, in: range, parameters: parameters).start(error: { _ in
            done.fulfill()
        }, completed: {
            done.fulfill()
        })
        self.wait(for: [done], timeout: 10.0)
        disposable.dispose()
        self.mediaBox.dataQueue.sync {}
    }

    func testDownloadedBytesAreCountedOnceUnderTheirMediaType() {
        let data = self.payload(100_000)
        self.installFetcher(data: data, partSize: 16 * 1024)
        let resource = TestResource("video-1", size: Int64(data.count))

        let videoBefore = DiskWriteAccounting.shared.bytesWritten("mediaBox.video")
        let stickerBefore = DiskWriteAccounting.shared.bytesWritten("mediaBox.sticker")
        self.fetchRange(resource, 0 ..< 40_000, contentType: 2)

        // The fetcher's parts cover 0 ..< 49,152 (three whole parts).
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten("mediaBox.video") - videoBefore, 49_152)
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten("mediaBox.sticker") - stickerBefore, 0)

        let sticker = TestResource("sticker-1", size: 1000)
        self.installFetcher(data: self.payload(1000), partSize: 16 * 1024)
        self.fetchRange(sticker, 0 ..< 1000, contentType: 6)
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten("mediaBox.sticker") - stickerBefore, 1000)
    }

    func testStoredRangesAndCachedRepresentationsAreCounted() {
        let id = MediaResourceId("stored-1")
        let untypedBefore = DiskWriteAccounting.shared.bytesWritten("mediaBox.untyped")
        let representationBefore = DiskWriteAccounting.shared.bytesWritten(DiskWriteCategory.mediaBoxCachedRepresentation)

        let status = self.mediaBox.resourceStatus(id, resourceSize: 10_000).start(next: { _ in })
        self.mediaBox.storeResourceData(id, range: 0 ..< 4000, data: self.payload(4000))
        self.mediaBox.dataQueue.sync {}
        status.dispose()
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten("mediaBox.untyped") - untypedBefore, 4000)

        let stored = self.expectation(description: "stored")
        self.mediaBox.storeCachedResourceRepresentation("stored-1", representationId: "thumb", keepDuration: .general, data: self.payload(300), completion: { _ in
            stored.fulfill()
        })
        self.wait(for: [stored], timeout: 10.0)
        XCTAssertEqual(DiskWriteAccounting.shared.bytesWritten(DiskWriteCategory.mediaBoxCachedRepresentation) - representationBefore, 300)
    }

    func testAResourceThatIsOnlyLookedAtWritesNoFiles() {
        let id = MediaResourceId("looked-at")
        let paths = self.mediaBox.storePathsForId(id)
        let mapBefore = DiskWriteAccounting.shared.snapshot().writes[DiskWriteCategory.mediaBoxMap] ?? 0

        let reported = self.expectation(description: "status")
        reported.assertForOverFulfill = false
        let status = self.mediaBox.resourceStatus(id, resourceSize: 10_000).start(next: { _ in
            reported.fulfill()
        })
        self.wait(for: [reported], timeout: 10.0)
        self.mediaBox.dataQueue.sync {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.partial + ".meta"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.partial))
        status.dispose()
        self.mediaBox.dataQueue.sync {}
        self.mediaBox.dataQueue.sync {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.partial + ".meta"))
        XCTAssertEqual(DiskWriteAccounting.shared.snapshot().writes[DiskWriteCategory.mediaBoxMap] ?? 0, mapBefore)
    }

    func testAPartialResourceStillGetsItsMapOnceItHasData() throws {
        let id = MediaResourceId("partial-with-data")
        let paths = self.mediaBox.storePathsForId(id)
        // The store opens the file context, writes and releases it; the context closes on the data queue.
        self.mediaBox.storeResourceData(id, range: 0 ..< 1000, data: self.payload(1000))
        self.mediaBox.dataQueue.sync {}
        self.mediaBox.dataQueue.sync {}

        // The context closed with an unsaved write, so the map reached the disk then.
        let map = try MediaBoxFileMap.read(manager: MediaBoxFileManager(queue: nil), path: paths.partial + ".meta")
        XCTAssertEqual(map.ranges.ranges.map { $0 }, [0 ..< 1000])
        XCTAssertTrue(self.mediaBox.internal_resourceDataIsCached(id: id, size: 10_000, in: 0 ..< 1000))
    }
}
