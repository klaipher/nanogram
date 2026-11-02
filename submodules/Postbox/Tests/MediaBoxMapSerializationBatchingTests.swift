import Foundation
import XCTest
import SwiftSignalKit
import RangeSet
@testable import Postbox

/// The partial file's map (`<id>_partial.meta`) was rewritten after every downloaded chunk.
/// It is now written every `defaultWritesPerMapSerialization` writes and on completion, reset,
/// truncation and close; this process's direct readers see the live map. These tests pin that
/// the map on disk never claims bytes that were not written (so a crash only costs a
/// re-download), that a torn map is still discarded on reopen, and that direct readers are
/// never behind.
final class MediaBoxMapSerializationBatchingTests: XCTestCase {
    private var queue: Queue!
    private var basePath: String!
    private var manager: MediaBoxFileManager!
    private var liveFileMaps: MediaBoxLiveFileMaps!

    private let chunk: Int64 = 4096

    private var fullPath: String { return self.basePath + "/resource" }
    private var partialPath: String { return self.basePath + "/resource_partial" }
    private var metaPath: String { return self.basePath + "/resource_partial.meta" }

    override func setUp() {
        super.setUp()
        self.queue = Queue(name: "MediaBoxMapSerializationBatchingTests")
        self.basePath = NSTemporaryDirectory() + "MediaBoxMapSerializationBatchingTests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
        self.manager = MediaBoxFileManager(queue: self.queue)
        self.liveFileMaps = MediaBoxLiveFileMaps()
    }

    override func tearDown() {
        self.manager = nil
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func makeContext(basePath: String? = nil, writesPerMapSerialization: Int = MediaBoxFileContextV2Impl.defaultWritesPerMapSerialization) -> MediaBoxFileContextV2Impl {
        let base = basePath ?? self.basePath!
        var context: MediaBoxFileContextV2Impl?
        self.queue.sync {
            context = MediaBoxFileContextV2Impl(
                queue: self.queue,
                manager: self.manager,
                storageBox: nil,
                resourceId: "resource".data(using: .utf8)!,
                path: base + "/resource",
                partialPath: base + "/resource_partial",
                metaPath: base + "/resource_partial.meta",
                liveFileMaps: self.liveFileMaps,
                writesPerMapSerialization: writesPerMapSerialization
            )
        }
        return context!
    }

    private func chunkData(_ index: Int) -> Data {
        return Data(repeating: UInt8(truncatingIfNeeded: index &* 37 &+ 1), count: Int(self.chunk))
    }

    private func store(_ context: MediaBoxFileContextV2Impl, chunks: Range<Int>) {
        self.queue.sync {
            for i in chunks {
                context.internalStore(data: self.chunkData(i), range: Int64(i) * self.chunk ..< Int64(i + 1) * self.chunk)
            }
        }
    }

    private func diskMap(_ metaPath: String? = nil) -> RangeSet<Int64>? {
        var result: RangeSet<Int64>?
        self.queue.sync {
            result = (try? MediaBoxFileMap.read(manager: MediaBoxFileManager(queue: nil), path: metaPath ?? self.metaPath))?.ranges
        }
        return result
    }

    private func reportedRanges(of context: MediaBoxFileContextV2Impl) -> RangeSet<Int64>? {
        var reported: RangeSet<Int64>?
        self.queue.sync {
            let _ = context.rangeStatus(next: { ranges in
                reported = ranges
            }, completed: {})
        }
        return reported
    }

    private func written(_ count: Int) -> RangeSet<Int64> {
        return count == 0 ? RangeSet() : RangeSet(0 ..< Int64(count) * self.chunk)
    }

    func testMapReachesTheDiskEveryNWritesAndOnClose() {
        let n = MediaBoxFileContextV2Impl.defaultWritesPerMapSerialization
        var context: MediaBoxFileContextV2Impl? = self.makeContext()
        self.store(context!, chunks: 0 ..< n - 1)
        XCTAssertEqual(self.diskMap(), RangeSet<Int64>(), "not yet written to disk")
        XCTAssertEqual(self.liveFileMaps.snapshot(metaPath: self.metaPath)?.ranges, self.written(n - 1), "but live")
        XCTAssertEqual(self.reportedRanges(of: context!), self.written(n - 1))

        self.store(context!, chunks: n - 1 ..< n + 3)
        XCTAssertEqual(self.diskMap(), self.written(n))

        self.queue.sync {
            context = nil
        }
        XCTAssertEqual(self.diskMap(), self.written(n + 3), "closing the context writes the rest")
        XCTAssertNil(self.liveFileMaps.snapshot(metaPath: self.metaPath))
    }

    // MediaBox.removeCachedResources(force: true) unlinks the partial file and its map behind the
    // file context's back and drops the context. Closing it must not write the map back: a map
    // without its partial file is an orphan, and one that a fresh partial file (another process
    // starting the same download) inherits claims bytes that file does not hold.
    func testClosingAfterTheFilesWereRemovedDoesNotRecreateTheMap() {
        var context: MediaBoxFileContextV2Impl? = self.makeContext()
        self.store(context!, chunks: 0 ..< 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.partialPath))
        unlink(self.partialPath)
        unlink(self.metaPath)
        self.queue.sync {
            context = nil
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.metaPath), "the map of a removed partial file was written back")
        XCTAssertNil(self.liveFileMaps.snapshot(metaPath: self.metaPath))
    }

    // A process killed between two map writes leaves a map that claims less than the partial
    // file holds. Reopening it keeps exactly what the map claims; the rest is downloaded again.
    func testMapLeftBehindByACrashOnlyClaimsWrittenBytes() throws {
        let n = MediaBoxFileContextV2Impl.defaultWritesPerMapSerialization
        var context: MediaBoxFileContextV2Impl? = self.makeContext()
        self.store(context!, chunks: 0 ..< n + 5)

        // Snapshot the files as a crash would leave them, before the context writes its map.
        let crashPath = self.basePath + "/crash"
        try FileManager.default.createDirectory(atPath: crashPath, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: self.partialPath, toPath: crashPath + "/resource_partial")
        try FileManager.default.copyItem(atPath: self.metaPath, toPath: crashPath + "/resource_partial.meta")

        var reopened: MediaBoxFileContextV2Impl? = self.makeContext(basePath: crashPath)
        XCTAssertEqual(self.reportedRanges(of: reopened!), self.written(n))
        let partial = try Data(contentsOf: URL(fileURLWithPath: crashPath + "/resource_partial"))
        for i in 0 ..< n {
            XCTAssertEqual(partial.subdata(in: i * Int(self.chunk) ..< (i + 1) * Int(self.chunk)), self.chunkData(i))
        }
        // File contexts are released on their queue, as MediaBox does.
        self.queue.sync {
            context = nil
            reopened = nil
        }
    }

    // A map torn by a crash in the middle of its write fails its length or checksum check and is
    // discarded, as before.
    func testTornMapIsDiscardedOnReopen() throws {
        let n = MediaBoxFileContextV2Impl.defaultWritesPerMapSerialization
        var context: MediaBoxFileContextV2Impl? = self.makeContext()
        self.store(context!, chunks: 0 ..< 3 * n)
        self.queue.sync {
            context = nil
        }
        XCTAssertEqual(self.diskMap(), self.written(3 * n))

        let meta = try Data(contentsOf: URL(fileURLWithPath: self.metaPath))
        for torn in [meta.prefix(meta.count / 2), meta.prefix(14)] {
            try Data(torn).write(to: URL(fileURLWithPath: self.metaPath))
            XCTAssertNil(self.diskMap())
            var reopened: MediaBoxFileContextV2Impl? = self.makeContext()
            XCTAssertEqual(self.reportedRanges(of: reopened!), RangeSet<Int64>())
            self.queue.sync {
                reopened = nil
            }
        }

        var corrupted = meta
        corrupted[corrupted.count - 1] ^= 0xFF
        try corrupted.write(to: URL(fileURLWithPath: self.metaPath))
        var reopened: MediaBoxFileContextV2Impl? = self.makeContext()
        XCTAssertEqual(self.reportedRanges(of: reopened!), RangeSet<Int64>())
        self.queue.sync {
            reopened = nil
        }
    }

    func testCompletionWritesTheMapAndLinksTheFile() throws {
        var context: MediaBoxFileContextV2Impl? = self.makeContext()
        self.queue.sync {
            let _ = context!.fetched(range: 0 ..< 5 * self.chunk, priority: .default, fetch: { _ in
                return Signal { subscriber in
                    for i in 0 ..< 5 {
                        subscriber.putNext(.dataPart(resourceOffset: Int64(i) * self.chunk, data: self.chunkData(i), range: 0 ..< self.chunk, complete: i == 4))
                    }
                    return EmptyDisposable
                }
            }, error: { _ in }, completed: {})
        }
        self.queue.sync {
        }
        XCTAssertEqual(self.diskMap(), self.written(5))
        let full = try Data(contentsOf: URL(fileURLWithPath: self.fullPath))
        XCTAssertEqual(full, (0 ..< 5).reduce(Data()) { $0 + self.chunkData($1) })
        self.queue.sync {
            context = nil
        }
    }

    // MediaBox's direct readers (the media players' readers) bypass the file context; they must
    // see a chunk as soon as it is written, not when the map next reaches the disk.
    func testDirectReadersSeeWritesBeforeTheMapReachesTheDisk() throws {
        let mediaBoxPath = self.basePath + "/media"
        try FileManager.default.createDirectory(atPath: mediaBoxPath, withIntermediateDirectories: true)
        let mediaBox = MediaBox(basePath: mediaBoxPath, isMainProcess: false)
        let id = MediaResourceId("direct-reader")
        // Keep the file context open, as a running fetch does.
        let statusReported = self.expectation(description: "status")
        statusReported.assertForOverFulfill = false
        let keepOpen = mediaBox.resourceStatus(id, resourceSize: 10 * self.chunk).start(next: { _ in
            statusReported.fulfill()
        })
        self.wait(for: [statusReported], timeout: 10.0)
        for i in 0 ..< 3 {
            mediaBox.storeResourceData(id, range: Int64(i) * self.chunk ..< Int64(i + 1) * self.chunk, data: self.chunkData(i))
        }
        let drained = self.expectation(description: "drained")
        mediaBox.dataQueue.async {
            drained.fulfill()
        }
        self.wait(for: [drained], timeout: 10.0)

        // The map on disk is behind: only the live map knows about these chunks.
        XCTAssertNil(try? MediaBoxFileMap.read(manager: MediaBoxFileManager(queue: nil), path: mediaBox.storePathsForId(id).partial + ".meta").ranges.ranges.first)
        XCTAssertTrue(mediaBox.internal_resourceDataIsCached(id: id, size: 10 * self.chunk, in: 0 ..< 3 * self.chunk))
        XCTAssertFalse(mediaBox.internal_resourceDataIsCached(id: id, size: 10 * self.chunk, in: 0 ..< 4 * self.chunk))
        let (file, length) = try XCTUnwrap(mediaBox.internal_resourceData(id: id, size: 10 * self.chunk, in: self.chunk ..< 3 * self.chunk))
        XCTAssertEqual(length, Int(2 * self.chunk))
        XCTAssertEqual(file.readData(count: length), self.chunkData(1) + self.chunkData(2))
        keepOpen.dispose()

        // The storage boxes open their databases lazily on their own queues (the writes above
        // queued size updates). Let them finish before tearDown deletes the directory, or the
        // open fails there and precondition-crashes the whole test process.
        let releasedContext = self.expectation(description: "context released")
        mediaBox.dataQueue.async {
            releasedContext.fulfill()
        }
        self.wait(for: [releasedContext], timeout: 10.0)
        for storageBox in [mediaBox.storageBox, mediaBox.cacheStorageBox] {
            let drained = self.expectation(description: "storage box drained")
            drained.assertForOverFulfill = false
            let disposable = storageBox.get(ids: []).start(next: { _ in
                drained.fulfill()
            })
            self.wait(for: [drained], timeout: 10.0)
            disposable.dispose()
        }
    }

    func testBenchmarkMapWritesPerChunk() {
        let chunks = 2000
        var times: [Int: Double] = [:]
        for interval in [1, MediaBoxFileContextV2Impl.defaultWritesPerMapSerialization] {
            let base = self.basePath + "/bench\(interval)"
            try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            var context: MediaBoxFileContextV2Impl? = self.makeContext(basePath: base, writesPerMapSerialization: interval)
            let data = Data(repeating: 1, count: 16 * 1024)
            let start = CFAbsoluteTimeGetCurrent()
            self.queue.sync {
                for i in 0 ..< chunks {
                    // Out of order, like parallel part downloads: the map holds many ranges.
                    let slot = (i * 7919) % chunks
                    context!.internalStore(data: data, range: Int64(slot) * 16384 ..< Int64(slot + 1) * 16384)
                }
                context = nil
            }
            times[interval] = CFAbsoluteTimeGetCurrent() - start
        }
        print("BENCH MediaBox \(chunks) x 16 KB partial writes: map every write \(String(format: "%.1f", times[1]! * 1000)) ms, every \(MediaBoxFileContextV2Impl.defaultWritesPerMapSerialization) writes \(String(format: "%.1f", times[MediaBoxFileContextV2Impl.defaultWritesPerMapSerialization]! * 1000)) ms")
    }
}
