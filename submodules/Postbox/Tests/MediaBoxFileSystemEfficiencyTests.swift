import Foundation
import XCTest
import SwiftSignalKit
import RangeSet
@testable import Postbox

/// File-system work on MediaBox hot paths, measured on device (Nanogram session 2026-11-01):
/// - `MediaBoxFileMap.serialize` opened, wrote and closed `<id>_partial.meta` on every partial
///   write (0.37 s of open() alone);
/// - the stale empty-partial sweep did one lstat per partial file at every cold start (0.57 s);
/// - every resource access re-touched its files every 10 s (0.49 s of utime).
final class MediaBoxFileSystemEfficiencyTests: XCTestCase {
    private var queue: Queue!
    private var basePath: String!

    override func setUp() {
        super.setUp()
        self.queue = Queue(name: "MediaBoxFileSystemEfficiencyTests")
        self.basePath = NSTemporaryDirectory() + "MediaBoxFileSystemEfficiencyTests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
    }

    override func tearDown() {
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func path(_ name: String) -> String {
        return self.basePath + "/" + name
    }

    private func setAge(_ path: String, seconds: Int) {
        let time = Int(Date().timeIntervalSince1970) - seconds
        var times = [timeval(tv_sec: time, tv_usec: 0), timeval(tv_sec: time, tv_usec: 0)]
        XCTAssertEqual(lutimes(path, &times), 0)
    }

    // MARK: - MediaBoxFileMap.serialize

    func testSerializingAMapAfterEveryWriteOpensTheMetaFileOnce() {
        let metaPath = self.path("res_partial.meta")
        self.queue.sync {
            let manager = MediaBoxFileManager(queue: self.queue)
            let map = MediaBoxFileMap()
            for i in 0 ..< 100 {
                map.fill(Int64(i) * 1000 ..< Int64(i) * 1000 + 500)
                map.serialize(manager: manager, to: metaPath)
            }
            // The first write opens and closes it; from the second on it stays open.
            XCTAssertEqual(manager.openedFileCount, 2)
        }
    }

    func testAMapSerializedOnceKeepsNoFileOpen() {
        self.queue.sync {
            let manager = MediaBoxFileManager(queue: self.queue)
            let map = MediaBoxFileMap()
            map.serialize(manager: manager, to: self.path("once_partial.meta"))
            XCTAssertEqual(manager.currentlyOpenFileCount, 0)
            withExtendedLifetime(map) {}
        }
    }

    func testAMapReleasedOffItsQueueClosesItsFileOnTheQueue() {
        var manager: MediaBoxFileManager!
        var map: MediaBoxFileMap? = MediaBoxFileMap()
        self.queue.sync {
            manager = MediaBoxFileManager(queue: self.queue)
            for i in 0 ..< 3 {
                map?.fill(Int64(i) * 10 ..< Int64(i) * 10 + 5)
                map?.serialize(manager: manager, to: self.path("offqueue_partial.meta"))
            }
            XCTAssertEqual(manager.currentlyOpenFileCount, 1)
        }
        // Released on the test thread: the file must be closed on the manager's queue
        // (MediaBoxFileManager asserts that), not here.
        map = nil
        self.queue.sync {}
        self.queue.sync {
            XCTAssertEqual(manager.currentlyOpenFileCount, 0)
        }
    }

    func testEachSerializationIsReadBackExactly() {
        let metaPath = self.path("res_partial.meta")
        self.queue.sync {
            let manager = MediaBoxFileManager(queue: self.queue)
            let map = MediaBoxFileMap()
            for i in 0 ..< 50 {
                map.fill(Int64(i) * 1000 ..< Int64(i) * 1000 + 500)
                if i == 20 {
                    map.truncate(123_456)
                }
                map.serialize(manager: manager, to: metaPath)

                let readManager = MediaBoxFileManager(queue: nil)
                let stored = try? MediaBoxFileMap.read(manager: readManager, path: metaPath)
                XCTAssertEqual(stored?.ranges, map.ranges)
                XCTAssertEqual(stored?.sum, map.sum)
                XCTAssertEqual(stored?.truncationSize, map.truncationSize)
            }
            // Fewer ranges than before: the count field decides, the old tail is ignored.
            map.reset()
            map.fill(0 ..< 10)
            map.serialize(manager: manager, to: metaPath)
            let stored = try? MediaBoxFileMap.read(manager: MediaBoxFileManager(queue: nil), path: metaPath)
            XCTAssertEqual(stored?.ranges, RangeSet<Int64>(0 ..< 10))
            XCTAssertEqual(stored?.sum, 10)
            XCTAssertNil(stored?.truncationSize)
        }
    }

    func testSerializationStaysCorrectWhenTheManagerClosesTheMetaFileForOtherFiles() {
        self.queue.sync {
            let manager = MediaBoxFileManager(queue: self.queue)
            var maps: [(MediaBoxFileMap, String)] = []
            for i in 0 ..< 40 {
                maps.append((MediaBoxFileMap(), self.path("res\(i)_partial.meta")))
            }
            for round in 0 ..< 5 {
                for (index, (map, metaPath)) in maps.enumerated() {
                    map.fill(Int64(round) * 100 + Int64(index) ..< Int64(round) * 100 + Int64(index) + 1)
                    map.serialize(manager: manager, to: metaPath)
                }
            }
            for (map, metaPath) in maps {
                let stored = try? MediaBoxFileMap.read(manager: MediaBoxFileManager(queue: nil), path: metaPath)
                XCTAssertEqual(stored?.ranges, map.ranges)
            }
        }
    }

    func testBenchmarkSerializeAfterEachWrite() {
        let iterations = 3000
        let metaPath = self.path("bench_partial.meta")
        var reopenTime: Double = 0
        var reuseTime: Double = 0
        self.queue.sync {
            let manager = MediaBoxFileManager(queue: self.queue)
            // Contiguous downloads: the map stays one range, like a real sequential fetch.
            let chunk: Int64 = 65536

            // Old behaviour: a file map without an open file (a fresh instance per write).
            var start = CFAbsoluteTimeGetCurrent()
            for i in 0 ..< iterations {
                let fresh = MediaBoxFileMap()
                fresh.fill(0 ..< Int64(i + 1) * chunk)
                fresh.serialize(manager: manager, to: metaPath)
            }
            reopenTime = CFAbsoluteTimeGetCurrent() - start

            let _ = unlink(metaPath)
            let map = MediaBoxFileMap()
            start = CFAbsoluteTimeGetCurrent()
            for i in 0 ..< iterations {
                map.fill(Int64(i) * chunk ..< Int64(i + 1) * chunk)
                map.serialize(manager: manager, to: metaPath)
            }
            reuseTime = CFAbsoluteTimeGetCurrent() - start
        }
        print("BENCH serialize x\(iterations): reopen each time \(String(format: "%.1f", reopenTime * 1000)) ms, reuse open file \(String(format: "%.1f", reuseTime * 1000)) ms")
    }

    // MARK: - Bulk directory listing

    func testBulkDirectoryEntriesMatchLstat() {
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("empty"), contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("data"), contents: Data(count: 12345)))
        XCTAssertEqual(link(self.path("data"), self.path("data-link")), 0)
        XCTAssertEqual(symlink(self.path("data"), self.path("symlink")), 0)
        try? FileManager.default.createDirectory(atPath: self.path("dir"), withIntermediateDirectories: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("ünïcode name_partial"), contents: nil))
        self.setAge(self.path("empty"), seconds: 3 * 86_400)
        for i in 0 ..< 3000 {
            XCTAssertTrue(FileManager.default.createFile(atPath: self.path("bulk-\(i)"), contents: Data(count: i % 7)))
        }

        guard let entries = bulkDirectoryEntries(path: self.basePath) else {
            XCTFail("getattrlistbulk failed")
            return
        }
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: self.basePath)) ?? []))
        XCTAssertEqual(Set(entries.map(\.name)), names)
        XCTAssertEqual(entries.count, names.count)

        for entry in entries {
            var value = stat()
            XCTAssertEqual(lstat(self.path(entry.name), &value), 0, entry.name)
            let isRegular = (value.st_mode & S_IFMT) == S_IFREG
            XCTAssertEqual(entry.isRegularFile, isRegular, entry.name)
            if isRegular {
                XCTAssertEqual(entry.size, Int64(value.st_size), entry.name)
                XCTAssertEqual(entry.linkCount, UInt32(value.st_nlink), entry.name)
                XCTAssertEqual(entry.modificationTime, Int(value.st_mtimespec.tv_sec), entry.name)
            }
        }
    }

    func testBulkDirectoryEntriesOfAMissingDirectoryIsNil() {
        XCTAssertNil(bulkDirectoryEntries(path: self.path("does-not-exist")))
    }

    private func makeSweepFixture(staleCount: Int, liveCount: Int) {
        let old = 2 * 86_400
        for i in 0 ..< staleCount {
            let name = "stale-\(i)_partial"
            XCTAssertTrue(FileManager.default.createFile(atPath: self.path(name), contents: nil))
            XCTAssertTrue(FileManager.default.createFile(atPath: self.path(name + ".meta"), contents: Data(count: 20)))
            self.setAge(self.path(name), seconds: old)
            self.setAge(self.path(name + ".meta"), seconds: old)
        }
        for i in 0 ..< liveCount {
            let name = "live-\(i)_partial"
            XCTAssertTrue(FileManager.default.createFile(atPath: self.path(name), contents: Data(count: 100)))
            XCTAssertTrue(FileManager.default.createFile(atPath: self.path(name + ".meta"), contents: Data(count: 20)))
            self.setAge(self.path(name), seconds: old)
            self.setAge(self.path(name + ".meta"), seconds: old)
            XCTAssertTrue(FileManager.default.createFile(atPath: self.path("complete-\(i)"), contents: Data(count: 10)))
        }
        // Edge cases the rule must keep or remove exactly as the lstat version does.
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("orphan_partial.meta"), contents: Data(count: 20)))
        self.setAge(self.path("orphan_partial.meta"), seconds: old)
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("recentorphan_partial.meta"), contents: Data(count: 20)))
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("bare_partial"), contents: nil))
        self.setAge(self.path("bare_partial"), seconds: old)
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("recent_partial"), contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("linked"), contents: nil))
        XCTAssertEqual(link(self.path("linked"), self.path("linked_partial")), 0)
        self.setAge(self.path("linked_partial"), seconds: old)
        XCTAssertEqual(symlink(self.path("bare_partial"), self.path("sym_partial")), 0)
        try? FileManager.default.createDirectory(atPath: self.path("dir_partial"), withIntermediateDirectories: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("freshmeta_partial"), contents: nil))
        self.setAge(self.path("freshmeta_partial"), seconds: old)
        XCTAssertTrue(FileManager.default.createFile(atPath: self.path("freshmeta_partial.meta"), contents: Data(count: 20)))
    }

    func testBulkSweepFindsExactlyTheSameCandidatesAsTheLstatSweep() {
        self.makeSweepFixture(staleCount: 200, liveCount: 200)
        let minTimestamp = Int(Date().timeIntervalSince1970) - 86_400
        let bulk = staleEmptyPartialFileCandidateIds(basePath: self.basePath, olderThan: minTimestamp, allowBulk: true)
        let lstatBased = staleEmptyPartialFileCandidateIds(basePath: self.basePath, olderThan: minTimestamp, allowBulk: false)
        XCTAssertEqual(Set(bulk), Set(lstatBased))
        XCTAssertEqual(bulk.count, Set(bulk).count)
        var expected = Set((0 ..< 200).map { "stale-\($0)" })
        expected.insert("orphan")
        expected.insert("bare")
        XCTAssertEqual(Set(bulk), expected)
    }

    func testBenchmarkStalePartialSweep() {
        self.makeSweepFixture(staleCount: 2000, liveCount: 8000)
        let minTimestamp = Int(Date().timeIntervalSince1970) - 86_400
        // Warm the directory cache equally for both.
        let _ = staleEmptyPartialFileCandidateIds(basePath: self.basePath, olderThan: minTimestamp, allowBulk: false)

        var start = CFAbsoluteTimeGetCurrent()
        let lstatBased = staleEmptyPartialFileCandidateIds(basePath: self.basePath, olderThan: minTimestamp, allowBulk: false)
        let lstatTime = CFAbsoluteTimeGetCurrent() - start

        start = CFAbsoluteTimeGetCurrent()
        let bulk = staleEmptyPartialFileCandidateIds(basePath: self.basePath, olderThan: minTimestamp, allowBulk: true)
        let bulkTime = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(Set(bulk), Set(lstatBased))
        print("BENCH stale sweep over \(((try? FileManager.default.contentsOfDirectory(atPath: self.basePath)) ?? []).count) files: lstat \(String(format: "%.1f", lstatTime * 1000)) ms, bulk \(String(format: "%.1f", bulkTime * 1000)) ms")
    }

    // MARK: - Touch throttling

    func testAPathTouchedRecentlyIsNotTouchedAgain() {
        var touches = RecentFileTouches(interval: 3600.0, maxCount: 100)
        XCTAssertEqual(Set(touches.pathsToTouch(["a", "b"], now: 1000.0)), ["a", "b"])
        XCTAssertEqual(touches.pathsToTouch(["a", "b"], now: 1010.0), [])
        XCTAssertEqual(touches.pathsToTouch(["a", "c"], now: 2000.0), ["c"])
        XCTAssertEqual(Set(touches.pathsToTouch(["a", "b", "c"], now: 1000.0 + 3600.0)), ["a", "b"])
    }

    // short-cache keeps a file 1 hour after its mtime (Account: setMaxStoreTimes(shortLived: 60 * 60)),
    // and the scan runs at launch: a throttle near an hour let it delete a file used minutes earlier.
    func testTheDefaultThrottleStaysWellBelowTheShortLivedStoreTime() {
        let shortLivedMaxStoreTime: Double = 60.0 * 60.0
        XCTAssertLessThanOrEqual(RecentFileTouches.defaultInterval, shortLivedMaxStoreTime / 10.0)

        var touches = RecentFileTouches()
        XCTAssertEqual(touches.pathsToTouch(["a"], now: 0.0), ["a"])
        XCTAssertEqual(touches.pathsToTouch(["a"], now: 50.0 * 60.0), ["a"])
    }

    func testAClockGoingBackwardsTouchesAgain() {
        var touches = RecentFileTouches(interval: 3600.0, maxCount: 100)
        XCTAssertEqual(touches.pathsToTouch(["a"], now: 5000.0), ["a"])
        XCTAssertEqual(touches.pathsToTouch(["a"], now: 4000.0), ["a"])
    }

    func testTheTouchMemoryStaysBounded() {
        var touches = RecentFileTouches(interval: 3600.0, maxCount: 1000)
        for i in 0 ..< 5 {
            let batch = Set((0 ..< 800).map { "p\(i)-\($0)" })
            XCTAssertEqual(touches.pathsToTouch(batch, now: 100.0 + Double(i)).count, 800)
            XCTAssertLessThanOrEqual(touches.count, 1000)
        }
    }
}
