import Foundation
import XCTest
@testable import DiskWriteAccounting

final class DiskWriteAccountingTests: XCTestCase {
    func testCountsBytesAndWritesPerCategory() {
        let accounting = DiskWriteAccounting()
        accounting.add("mediaBox.video", bytes: 1000)
        accounting.add("mediaBox.video", bytes: 24)
        accounting.add("logs", bytes: 0)
        let snapshot = accounting.snapshot()
        XCTAssertEqual(snapshot.bytes["mediaBox.video"], 1024)
        XCTAssertEqual(snapshot.writes["mediaBox.video"], 2)
        XCTAssertEqual(snapshot.writes["logs"], 1)
        XCTAssertEqual(accounting.bytesWritten(prefix: "mediaBox."), 1024)
        XCTAssertEqual(snapshot.totalBytes, 1024)
    }

    func testCountsFromManyThreads() {
        let accounting = DiskWriteAccounting()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            accounting.add("x", bytes: 3)
        }
        XCTAssertEqual(accounting.bytesWritten("x"), 3000)
    }

    func testMediaBoxCategoriesFollowTheStoredContentTypes() {
        XCTAssertEqual(DiskWriteCategory.mediaBox(contentType: 2), "mediaBox.video")
        XCTAssertEqual(DiskWriteCategory.mediaBox(contentType: 6), "mediaBox.sticker")
        XCTAssertEqual(DiskWriteCategory.mediaBox(contentType: 9), "mediaBox.story")
        XCTAssertEqual(DiskWriteCategory.mediaBox(contentType: nil), "mediaBox.untyped")
        XCTAssertEqual(DiskWriteCategory.mediaBox(contentType: 42), "mediaBox.type42")
        XCTAssertEqual(DiskWriteCategory.databaseName(path: "/a/b/account-1/postbox/db"), "postbox/db")
    }

    func testSnapshotDifferenceHasOnlyWhatWasWrittenAfter() {
        let earlier = DiskWriteSnapshot(bytes: ["a": 10, "b": 5], writes: ["a": 1, "b": 1])
        let later = DiskWriteSnapshot(bytes: ["a": 30, "b": 5, "c": 7], writes: ["a": 3, "b": 1, "c": 1])
        let delta = later.subtracting(earlier)
        XCTAssertEqual(delta.bytes, ["a": 20, "c": 7])
        XCTAssertEqual(delta.writes, ["a": 2, "c": 1])
        XCTAssertEqual(delta.sortedCategories, ["a", "c"])
    }

    func testFormatsTheLargestCategoriesAndSumsTheRest() {
        let snapshot = DiskWriteSnapshot(bytes: ["a": 3 * 1024 * 1024, "b": 2048, "c": 10], writes: ["a": 3, "b": 2, "c": 1])
        XCTAssertEqual(snapshot.formattedCategories(limit: 2), "a 3.0 MB (3 writes), b 2.0 KB (2 writes), others 10 B (1 writes)")
    }

    func testReporterAccountsEachWriteOnceAndKeepsADailyLedger() throws {
        let directory = NSTemporaryDirectory() + "DiskWriteAccountingTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            let _ = try? FileManager.default.removeItem(atPath: directory)
        }
        let ledgerPath = directory + "/disk-writes.json"

        let accounting = DiskWriteAccounting()
        let reporter = DiskWriteAccountingReporter(accounting: accounting, ledgerPath: ledgerPath)
        accounting.add("mediaBox.video", bytes: 2 * 1024 * 1024)
        let first = reporter.report(reason: "hourly")
        XCTAssertTrue(first.hasPrefix("Disk writes (hourly): 2.0 MB in 0 min; mediaBox.video 2.0 MB (1 writes)"), first)

        accounting.add("logs", bytes: 1024)
        let second = reporter.report(reason: "background")
        XCTAssertTrue(second.hasPrefix("Disk writes (background): 1.0 KB in 0 min; logs 1.0 KB (1 writes)"), second)

        // A new launch reads the same ledger and adds to the same day.
        let day = DiskWriteAccountingReporter.dayKey(Date())
        let stored = DiskWriteLedger.load(path: ledgerPath)
        XCTAssertEqual(stored.days[day]?.bytes, ["mediaBox.video": 2 * 1024 * 1024, "logs": 1024])

        let nextLaunch = DiskWriteAccounting()
        let nextReporter = DiskWriteAccountingReporter(accounting: nextLaunch, ledgerPath: ledgerPath)
        nextLaunch.add("logs", bytes: 1024)
        nextReporter.report(reason: "hourly")
        XCTAssertEqual(DiskWriteLedger.load(path: ledgerPath).days[day]?.bytes["logs"], 2048)
        XCTAssertTrue(nextReporter.summary().contains("\(day): 2.0 MB"))
    }

    /// Before iOS may suspend the app (and kill it while suspended, without a later report), what was written since
    /// the last report reaches the ledger: a background-launched process (a push) never sees an hourly or a
    /// foreground report, so its writes were lost. Small amounts wait for the next report, so the ledger file is not
    /// rewritten on every wakeup.
    func testAReportBeforeSuspensionReachesTheLedgerOnlyPastItsMinimum() throws {
        let directory = NSTemporaryDirectory() + "DiskWriteAccountingTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            let _ = try? FileManager.default.removeItem(atPath: directory)
        }
        let ledgerPath = directory + "/disk-writes.json"
        let accounting = DiskWriteAccounting()
        let reporter = DiskWriteAccountingReporter(accounting: accounting, ledgerPath: ledgerPath)

        accounting.add("logs", bytes: 1000)
        XCTAssertNil(reporter.reportIfPending(atLeast: 1024 * 1024, reason: "suspend"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerPath), "a small amount does not rewrite the ledger")

        accounting.add("sqlite.wal.postbox/db", bytes: 2 * 1024 * 1024)
        let line = reporter.reportIfPending(atLeast: 1024 * 1024, reason: "suspend")
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.hasPrefix("Disk writes (suspend): 2.0 MB") == true, line ?? "")

        // The process is killed while suspended: the next launch finds both amounts in the ledger.
        let day = DiskWriteAccountingReporter.dayKey(Date())
        XCTAssertEqual(DiskWriteLedger.load(path: ledgerPath).days[day]?.bytes, ["logs": 1000, "sqlite.wal.postbox/db": 2 * 1024 * 1024])
    }

    func testAReportWithNothingWrittenDoesNotRewriteTheLedger() throws {
        let directory = NSTemporaryDirectory() + "DiskWriteAccountingTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            let _ = try? FileManager.default.removeItem(atPath: directory)
        }
        let ledgerPath = directory + "/disk-writes.json"
        let reporter = DiskWriteAccountingReporter(accounting: DiskWriteAccounting(), ledgerPath: ledgerPath)
        reporter.report(reason: "hourly")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerPath))
    }

    func testTheLedgerKeepsTwoWeeks() {
        var ledger = DiskWriteLedger()
        for day in 1 ... 20 {
            ledger.add(DiskWriteSnapshot(bytes: ["a": 1], writes: ["a": 1]), day: day < 10 ? "2026-10-0\(day)" : "2026-10-\(day)")
        }
        XCTAssertEqual(ledger.days.count, DiskWriteLedger.keptDays)
        XCTAssertNil(ledger.days["2026-10-06"])
        XCTAssertNotNil(ledger.days["2026-10-07"])
    }

    func testCallSitesAreKeptApartFromTheTotalsAndReachTheLedger() throws {
        let directory = NSTemporaryDirectory() + "DiskWriteLedgerSites-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            let _ = try? FileManager.default.removeItem(atPath: directory)
        }
        let ledgerPath = directory + "/disk-writes.json"
        let accounting = DiskWriteAccounting()
        let reporter = DiskWriteAccountingReporter(accounting: accounting, ledgerPath: ledgerPath)
        accounting.add(DiskWriteCategory.sqliteWal(database: "postbox/db"), bytes: 8192)
        accounting.addSite("A.swift:1", bytes: 4096)
        accounting.addSite("A.swift:1", bytes: 4096)
        accounting.addSite("B.swift:2", bytes: 100)
        reporter.report(reason: "hourly")
        accounting.addSite("B.swift:2", bytes: 50)
        reporter.report(reason: "hourly")

        let day = try XCTUnwrap(DiskWriteLedger.load(path: ledgerPath).days.values.first)
        XCTAssertEqual(day.snapshot.totalBytes, 8192, "call sites are a breakdown, not extra bytes")
        XCTAssertEqual(day.siteBytes, ["A.swift:1": 8192, "B.swift:2": 150])
        XCTAssertEqual(day.siteWrites, ["A.swift:1": 2, "B.swift:2": 2])
        XCTAssertEqual(day.snapshot.topSites(limit: 1).first?.site, "A.swift:1")
        XCTAssertTrue(DiskWriteLedger.load(path: ledgerPath).formattedDays().contains("A.swift:1 8.0 KB (2 commits)"))
    }

    func testTheLedgerKeepsTheBiggestCallSitesOfADay() {
        var ledger = DiskWriteLedger()
        var siteBytes: [String: Int64] = [:]
        var siteWrites: [String: Int64] = [:]
        for index in 1 ... 30 {
            siteBytes["S.swift:\(index)"] = Int64(index)
            siteWrites["S.swift:\(index)"] = 1
        }
        ledger.add(DiskWriteSnapshot(siteBytes: siteBytes, siteWrites: siteWrites), day: "2026-11-13")
        let day = ledger.days["2026-11-13"]
        XCTAssertEqual(day?.siteBytes.count, DiskWriteLedger.keptSites)
        XCTAssertNotNil(day?.siteBytes["S.swift:30"])
        XCTAssertNil(day?.siteBytes["S.swift:1"])
    }

    func testLaunchAndResumeDurationsFormADayHistogramInTheLedger() throws {
        let directory = NSTemporaryDirectory() + "DiskWriteLedgerLaunch-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            let _ = try? FileManager.default.removeItem(atPath: directory)
        }
        let ledgerPath = directory + "/disk-writes.json"
        let accounting = DiskWriteAccounting()
        let reporter = DiskWriteAccountingReporter(accounting: accounting, ledgerPath: ledgerPath)
        LaunchHistogram.record("launch.firstFrame", seconds: 0.18, accounting: accounting)
        LaunchHistogram.record("launch.firstFrame", seconds: 0.2, accounting: accounting)
        LaunchHistogram.record("launch.firstFrame", seconds: 7.5, accounting: accounting)
        LaunchHistogram.record("resume.firstFrame", seconds: 0.012, accounting: accounting)
        LaunchHistogram.record("resume.firstFrame", seconds: -1.0, accounting: accounting)
        reporter.report(reason: "hourly")

        let day = try XCTUnwrap(DiskWriteLedger.load(path: ledgerPath).days.values.first)
        XCTAssertEqual(day.counters["launch.firstFrame.le250ms"], 2)
        XCTAssertEqual(day.counters["launch.firstFrame.gt5000ms"], 1)
        XCTAssertEqual(day.counters["launch.firstFrame.count"], 3)
        XCTAssertEqual(day.counters["launch.firstFrame.sumMs"], 180 + 200 + 7500)
        XCTAssertEqual(day.counters["resume.firstFrame.le100ms"], 1)
        XCTAssertEqual(day.counters["resume.firstFrame.count"], 1)
        XCTAssertEqual(day.snapshot.totalBytes, 0, "counters are not disk writes")
        XCTAssertTrue(DiskWriteLedger.load(path: ledgerPath).formattedDays().contains("launch.firstFrame.count=3"))
        XCTAssertEqual(LaunchHistogram.bucketName(milliseconds: 100), "le100ms")
        XCTAssertEqual(LaunchHistogram.bucketName(milliseconds: 101), "le250ms")
    }

    func testALedgerWrittenBeforeCallSitesStillLoads() throws {
        let json = #"{"days":{"2026-11-12":{"bytes":{"logs":5},"writes":{"logs":1}}}}"#
        let ledger = try JSONDecoder().decode(DiskWriteLedger.self, from: Data(json.utf8))
        XCTAssertEqual(ledger.days["2026-11-12"]?.bytes["logs"], 5)
        XCTAssertEqual(ledger.days["2026-11-12"]?.siteBytes, [:])
    }
}

final class DiskWriteAccountingReportingTests: XCTestCase {
    func testTheAppReporterIsInstalledOnce() {
        let first = DiskWriteAccountingReporting.install(ledgerPath: NSTemporaryDirectory() + "a.json")
        let second = DiskWriteAccountingReporting.install(ledgerPath: NSTemporaryDirectory() + "b.json")
        XCTAssertTrue(first === second)
        XCTAssertTrue(DiskWriteAccountingReporting.current === first)
        XCTAssertEqual(DiskWriteAccountingReporting.ledgerPath, NSTemporaryDirectory() + "a.json")
    }
}
