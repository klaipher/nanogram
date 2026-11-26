import XCTest
@testable import tgwatch_Watch_App

/// The watch's part of the iPhone's "Send Report": its energy numbers, its report files, and the payload size.
final class WatchDiagnosticsTests: XCTestCase {
    private let context = EnergyContext(batteryPercent: 71, power: .unplugged, lowPowerMode: false, thermal: "nominal")

    func testReportHasManifestInfoEnergyAndLog() {
        let payload = WatchReportBuilder.payload(WatchReportInputs(created: Date(timeIntervalSince1970: 0), appVersion: "1.0", buildNumber: "9", bundleId: "x.watchkitapp", osVersion: "watchOS 26.1", modelIdentifier: "Watch7,1", context: context, energyText: "energy", logText: "log line\n", logNote: "note", journalText: "journal line\n"))
        XCTAssertEqual(payload.files.map(\.name), ["manifest.txt", "info.txt", "energy.txt", "log.txt", "journal.txt"])
        XCTAssertTrue(payload.files[0].text.contains("log.txt: note"))
        XCTAssertTrue(payload.files[0].text.contains("journal.txt: "))
        XCTAssertEqual(payload.files[4].text, "journal line\n")
        XCTAssertTrue(payload.files[1].text.contains("Watch7,1"))
        XCTAssertTrue(payload.files[1].text.contains("battery 71%"))
    }

    func testPayloadFitsTheMessageSize() {
        let log = String(repeating: "2026-11-14T10:00:00Z [x] some log line\n", count: 40_000)
        let payload = WatchReportPayload(created: Date(), files: [WatchReportFile(name: "log.txt", text: log)])
        let data = payload.encoded()
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data?.count ?? Int.max, WatchReportMessage.maximumBytes)
    }

    /// A 20 h launch came back "0 of 0": the note must say watchOS kept nothing and point to the journal.
    func testLogNoteSaysWhenWatchOSKeptNothing() {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let note = WatchReportBuilder.logNote(kept: 0, total: 0, launch: launch, now: launch.addingTimeInterval(20.4 * 3600))
        XCTAssertTrue(note.contains("watchOS kept none"), note)
        XCTAssertTrue(note.contains("20.4 h ago"), note)
        XCTAssertTrue(note.contains("journal.txt"), note)
        XCTAssertFalse(note.contains("0 of 0"), note)
    }

    func testLogNoteCountsKeptLines() {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let note = WatchReportBuilder.logNote(kept: 4000, total: 5123, launch: launch, now: launch.addingTimeInterval(60))
        XCTAssertTrue(note.contains("4000 of 5123, newest kept"), note)
        XCTAssertTrue(note.contains("journal.txt"), note)
    }

    func testLogNoteNeverShowsANegativeAge() {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let note = WatchReportBuilder.logNote(kept: 0, total: 0, launch: launch, now: launch.addingTimeInterval(-3600))
        XCTAssertTrue(note.contains("0.0 h ago"), note)
    }
}
