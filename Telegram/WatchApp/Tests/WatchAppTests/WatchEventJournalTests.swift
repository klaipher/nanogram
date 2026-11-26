import XCTest
@testable import tgwatch_Watch_App

/// The watch app's own event list, shipped as journal.txt in the iPhone's "Send Report". watchOS dropped every log
/// line of a 20 h launch before it was reported (log.txt "0 of 0"); the journal keeps a short, public record that
/// survives that and earlier launches.
final class WatchEventJournalTests: XCTestCase {
    private var directory: URL?

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-tests-\(UUID().uuidString)", isDirectory: true)
        directory = url
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fileURL() throws -> URL {
        let directory = try XCTUnwrap(directory)
        return directory.appendingPathComponent("nested", isDirectory: true).appendingPathComponent("journal.json")
    }

    func testKeepsOnlyTheNewestEntries() {
        let journal = WatchEventJournal(fileURL: nil)
        for index in 0 ..< WatchEventJournal.maximumEntries + 25 {
            journal.record("test", "event", detail: "\(index)")
        }
        let entries = journal.snapshot()
        XCTAssertEqual(entries.count, WatchEventJournal.maximumEntries)
        XCTAssertEqual(entries.first?.detail, "25")
        XCTAssertEqual(entries.last?.detail, "\(WatchEventJournal.maximumEntries + 24)")
    }

    func testDropsEntriesOlderThanTheMaximumAge() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let journal = WatchEventJournal(fileURL: nil, now: { clock.now })
        journal.record("test", "old")
        clock.advance(WatchEventJournal.maximumAge + 1)
        journal.record("test", "new")
        XCTAssertEqual(journal.snapshot().map(\.event), ["new"])
    }

    func testCutsLongDetails() {
        let journal = WatchEventJournal(fileURL: nil)
        journal.record("test", "event", detail: String(repeating: "x", count: 1000))
        XCTAssertEqual(journal.snapshot().first?.detail?.count, WatchEventJournal.maximumDetailLength)
    }

    func testSurvivesAReload() throws {
        let url = try fileURL()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000.25))
        let first = WatchEventJournal(fileURL: url, now: { clock.now })
        first.record("app", "launch", detail: "13.2 (202611232311)")
        clock.advance(5)
        first.record("tdlib", "authState", detail: "ready")
        first.flushNow()

        let second = WatchEventJournal(fileURL: url, now: { clock.now })
        XCTAssertEqual(second.snapshot(), first.snapshot())
        XCTAssertEqual(second.snapshot().map(\.event), ["launch", "authState"])
    }

    func testReloadDropsEntriesThatAgedOut() throws {
        let url = try fileURL()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let first = WatchEventJournal(fileURL: url, now: { clock.now })
        first.record("app", "launch")
        first.flushNow()
        clock.advance(WatchEventJournal.maximumAge + 60)
        XCTAssertTrue(WatchEventJournal(fileURL: url, now: { clock.now }).snapshot().isEmpty)
    }

    func testWritesOnlyWhenSomethingChanged() throws {
        let url = try fileURL()
        let journal = WatchEventJournal(fileURL: url)
        journal.flushNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing recorded, nothing written")
        journal.record("app", "launch")
        journal.flushNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: url)
        journal.flushNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no new entry since the last write")
    }

    func testAsyncFlushLandsOnDisk() throws {
        let url = try fileURL()
        let journal = WatchEventJournal(fileURL: url)
        journal.record("report", "copy handed to the phone")
        journal.flush()
        journal.waitForWrites()
        XCTAssertEqual(WatchEventJournal(fileURL: url).snapshot().map(\.event), ["copy handed to the phone"])
    }

    func testUnreadableFileStartsEmpty() throws {
        let url = try fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(WatchEventJournal(fileURL: url).snapshot().isEmpty)
    }

    func testTextHasOneLinePerEntry() {
        let entries = [
            WatchJournalEntry(date: Date(timeIntervalSince1970: 0), category: "app", event: "launch", detail: "13.2 (9)"),
            WatchJournalEntry(date: Date(timeIntervalSince1970: 60), category: "refresh", event: "background refresh done", detail: nil)
        ]
        XCTAssertEqual(WatchEventJournal.text(entries), "1970-01-01T00:00:00Z [app] launch: 13.2 (9)\n1970-01-01T00:01:00Z [refresh] background refresh done\n")
        XCTAssertEqual(WatchEventJournal.text([]), "(no events recorded)\n")
    }

    func testFullJournalFitsTheReplyWithItsNewestLine() {
        let journal = WatchEventJournal(fileURL: nil)
        for index in 0 ..< WatchEventJournal.maximumEntries {
            journal.record("tdlib", "authState", detail: String(repeating: "y", count: WatchEventJournal.maximumDetailLength - 5) + "\(10_000 + index)")
        }
        let log = String(repeating: "2026-11-14T10:00:00Z [x] some log line\n", count: 4000)
        let context = EnergyContext(batteryPercent: 50, power: .unplugged, lowPowerMode: false, thermal: "nominal")
        let payload = WatchReportBuilder.payload(WatchReportInputs(created: Date(), appVersion: "1.0", buildNumber: "9", bundleId: "x.watchkitapp", osVersion: "watchOS 27.2", modelIdentifier: "Watch7,1", context: context, energyText: "energy", logText: log, logNote: "note", journalText: journal.text()))
        let data = payload.encoded(maximumBytes: WatchReportMessage.maximumReplyBytes)
        XCTAssertLessThanOrEqual(data?.count ?? Int.max, WatchReportMessage.maximumReplyBytes)
        let decoded = data.flatMap { WatchReportPayload.decode($0) }
        let journalFile = decoded?.files.first { $0.name == "journal.txt" }
        XCTAssertTrue(journalFile?.text.contains("\(10_000 + WatchEventJournal.maximumEntries - 1)") ?? false, "the newest event survives the cut")
    }
}

/// A clock the tests move by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}
