import XCTest
import ZipArchive
import WatchReport
@testable import DebugSettingsUI

/// The tester's one "Send Report": what the zip holds, the README that lists it, the size caps and the masking.
final class DebugReportTests: XCTestCase {
    private func source(_ section: DebugReportSection, _ name: String, size: Int64, age: Double, treatment: DebugReportTreatment = .redactedText) -> DebugReportSource {
        return DebugReportSource(section: section, name: name, path: "/nonexistent/\(name)", treatment: treatment, modified: Date(timeIntervalSince1970: 1_000_000 - age), size: size)
    }

    func testReportKindIsOneSendReportWithTheNoteAndAChatConfirmation() {
        let spec = debugLogExportSpec(.report, appVersion: "13.2", buildNumber: "1")
        XCTAssertEqual(spec.sheetTitle, "Send Report")
        XCTAssertEqual(spec.fileBaseName, "nanogram-logs-report")
        XCTAssertEqual(spec.note, debugReportPrivacyNote)
        XCTAssertTrue(spec.confirmsChatSend)
        XCTAssertFalse(debugReportPrivacyNote.contains("\n"))
    }

    func testNewestFilesWinUnderTheTotalCap() {
        let limits = DebugReportLimits(totalBytes: 100, sectionBytes: 100, fileBytes: 100)
        let plan = debugReportPlan(sources: [
            source(.appLogs, "old", size: 60, age: 100),
            source(.appLogs, "new", size: 60, age: 1),
            source(.crashes, "crash", size: 30, age: 500)
        ], limits: limits)
        XCTAssertEqual(plan.entries.map { $0.source.name }, ["crash", "new"])
        XCTAssertEqual(plan.omitted.map(\.name), ["old"])
    }

    func testSectionCapKeepsOneSectionFromTakingEverything() {
        let limits = DebugReportLimits(totalBytes: 100, sectionBytes: 40, fileBytes: 100)
        let plan = debugReportPlan(sources: [
            source(.appLogs, "a", size: 30, age: 1),
            source(.appLogs, "b", size: 30, age: 2),
            source(.notificationLogs, "n", size: 30, age: 3)
        ], limits: limits)
        XCTAssertEqual(plan.entries.map { $0.source.name }, ["a", "n"])
        XCTAssertEqual(plan.omitted.map(\.name), ["b"])
    }

    func testBigTextIsCutAndBigUnchangedFilesAreLeftOut() {
        let limits = DebugReportLimits(totalBytes: 1000, sectionBytes: 1000, fileBytes: 50)
        let plan = debugReportPlan(sources: [
            source(.appLogs, "log", size: 500, age: 1),
            source(.metricKit, "metric.json", size: 500, age: 1, treatment: .unchanged)
        ], limits: limits)
        XCTAssertEqual(plan.entries.map { $0.source.name }, ["log"])
        XCTAssertEqual(plan.entries.first?.bytes, 50)
        XCTAssertEqual(plan.entries.first?.isCut, true)
        XCTAssertEqual(plan.omitted.map(\.name), ["metric.json"])
    }

    func testInfoIsAlwaysKept() {
        let limits = DebugReportLimits(totalBytes: 1, sectionBytes: 1, fileBytes: 1000)
        let plan = debugReportPlan(sources: [DebugReportSource(section: .info, name: "info.txt", text: "device", modified: Date())], limits: limits)
        XCTAssertEqual(plan.entries.map(\.entryName), ["info/info.txt"])
    }

    func testEntryNamesAreSafeAndUnique() {
        let plan = debugReportPlan(sources: [
            source(.appLogs, "log-a.txt", size: 1, age: 1),
            source(.appLogs, "../log-a.txt", size: 1, age: 2),
            source(.callLogs, "a b?.log", size: 1, age: 1)
        ])
        XCTAssertEqual(Set(plan.entries.map(\.entryName)).count, 3)
        for entry in plan.entries {
            XCTAssertFalse(entry.entryName.contains(".."))
            XCTAssertFalse(entry.entryName.contains(" "))
        }
        XCTAssertTrue(plan.entries.contains { $0.entryName == "calls/a_b_.log" })
    }

    func testManifestListsEveryPartAndWhatIsMissing() {
        let plan = debugReportPlan(sources: [
            source(.appLogs, "log-1.txt", size: 2048, age: 1),
            source(.appLogs, "log-2.txt", size: 10 * 1024 * 1024, age: 2)
        ], limits: DebugReportLimits(totalBytes: 5000, sectionBytes: 5000, fileBytes: 4096))
        let manifest = debugReportManifest(infoLines: ["App: Nanogram iOS 13.2 (1)"], plan: plan, created: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(manifest.hasPrefix("Nanogram report\n"))
        XCTAssertTrue(manifest.contains("App: Nanogram iOS 13.2 (1)"))
        XCTAssertTrue(manifest.contains(debugReportPrivacyNote))
        for section in DebugReportSection.allCases {
            XCTAssertTrue(manifest.contains(section.title), "\(section)")
        }
        XCTAssertTrue(manifest.contains("logs/app/log-1.txt"))
        XCTAssertTrue(manifest.contains("Crash reports [crashes/]: none on this device"))
        XCTAssertTrue(manifest.contains("left out: log-2.txt"))
    }

    func testRedactionMasksPhonesAndEmailsOnly() {
        let text = "user +380 67 123 45 67 mail Jane.Doe@example.com id 1234567890123 build 202611031553 peer=-1001234567"
        let result = debugReportRedacted(text)
        XCTAssertEqual(result, "user [phone] mail [email] id 1234567890123 build 202611031553 peer=-1001234567")
    }

    func testTailKeepsTheNewestWholeLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("log.txt")
        try Data("line1\nline2\nline3\n".utf8).write(to: url)
        let cut = String(decoding: try XCTUnwrap(debugReportTail(of: url, limit: 8)), as: UTF8.self)
        XCTAssertTrue(cut.hasPrefix("[earlier lines cut"))
        XCTAssertTrue(cut.hasSuffix("line3\n"))
        XCTAssertFalse(cut.contains("line1"))
        let whole = String(decoding: try XCTUnwrap(debugReportTail(of: url, limit: 100)), as: UTF8.self)
        XCTAssertEqual(whole, "line1\nline2\nline3\n")
    }

    func testArchiveHoldsReadmeRedactedTextAndUnchangedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("log-1.txt")
        try Data("call from +49 151 2345678 ok\n".utf8).write(to: log)
        let json = directory.appendingPathComponent("metric-1.json")
        let jsonData = Data("{\"mail\":\"a@b.co\"}".utf8)
        try jsonData.write(to: json)
        let sources = [
            DebugReportSource(section: .info, name: "device.txt", text: "Device: iPhone15,2 owner a@b.co", modified: Date()),
            DebugReportSource(section: .appLogs, name: "log-1.txt", path: log.path, treatment: .redactedText, modified: Date(), size: 30),
            DebugReportSource(section: .metricKit, name: "metric-1.json", path: json.path, treatment: .unchanged, modified: Date(), size: Int64(jsonData.count))
        ]
        let plan = debugReportPlan(sources: sources)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = try XCTUnwrap(debugReportArchive(plan: plan, manifest: debugReportManifest(infoLines: [], plan: plan, created: Date()), baseName: "nanogram-logs-report", in: output))
        XCTAssertEqual(file.name, "nanogram-logs-report.zip")
        let unzipped = directory.appendingPathComponent("unzipped", isDirectory: true)
        XCTAssertTrue(SSZipArchive.unzipFile(atPath: file.path, toDestination: unzipped.path))
        let root = unzipped.appendingPathComponent("nanogram-logs-report")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.txt").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("info/device.txt")), "Device: iPhone15,2 owner [email]")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("logs/app/log-1.txt")), "call from [phone] ok\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("metrickit/metric-1.json")), jsonData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("nanogram-logs-report").path), "staging is removed")
    }

    func testCallLogsSurviveFullAppAndNotificationLogs() {
        let limits = DebugReportLimits(totalBytes: 100, sectionBytes: 60, fileBytes: 100)
        let plan = debugReportPlan(sources: [
            source(.appLogs, "app", size: 60, age: 1),
            source(.notificationLogs, "nse", size: 60, age: 1),
            source(.callLogs, "call.log", size: 10, age: 1)
        ], limits: limits)
        XCTAssertTrue(plan.entries.contains { $0.source.name == "call.log" })
    }

    /// The shape of the 2026-11-25 report: 22 critical logs of the last days, 9 old notification-extension critical logs,
    /// two-week-old app and notification-extension text logs (Log to File off). The 16 MB section cap cut the critical log
    /// that covered a memory kill three days earlier.
    func testCriticalLogsOfTheLastDaysAreKeptAheadOfOldLogs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let megabyte: Int64 = 1024 * 1024
        let hour: Double = 3600
        let day: Double = 24 * hour
        var sources: [DebugReportSource] = []
        for index in 0 ..< 22 {
            sources.append(source(.criticalLogs, "app-critlog-\(index)", size: megabyte, age: hour + Double(index) * 4 * hour, treatment: .unchanged))
        }
        for index in 0 ..< 9 {
            sources.append(source(.criticalLogs, "nse-critlog-\(index)", size: megabyte, age: 8 * day + Double(index) * day, treatment: .unchanged))
        }
        for index in 0 ..< 19 {
            sources.append(source(.appLogs, "app-log-\(index)", size: 2 * megabyte, age: 14 * day + Double(index) * 60))
        }
        for index in 0 ..< 4 {
            sources.append(source(.notificationLogs, "nse-log-\(index)", size: 2 * megabyte, age: 15 * day + Double(index) * day))
        }
        sources.append(source(.metricKit, "metric.json", size: 2 * megabyte, age: day, treatment: .unchanged))
        let plan = debugReportPlan(sources: sources, now: now)
        let kept = Set(plan.entries.map { $0.source.name })
        for index in 0 ..< 22 {
            XCTAssertTrue(kept.contains("app-critlog-\(index)"), "app-critlog-\(index)")
        }
        let critical = plan.entries.filter { $0.source.section == .criticalLogs }
        XCTAssertEqual(critical.count, 28)
        XCTAssertEqual(critical.reduce(0) { $0 + $1.bytes }, 28 * megabyte)
        XCTAssertTrue(kept.contains("metric.json"))
        XCTAssertEqual(plan.entries.filter { $0.source.section == .appLogs }.count, 5, "old text logs fill only the room left")
        XCTAssertEqual(plan.entries.filter { $0.source.section == .notificationLogs }.count, 0)
        XCTAssertEqual(plan.entries.reduce(0) { $0 + $1.bytes }, 40 * megabyte)
    }

    func testTheLargerCriticalCapAppliesOnlyToCriticalLogs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let limits = DebugReportLimits(totalBytes: 1000, sectionBytes: 40, fileBytes: 100, criticalLogSectionBytes: 60)
        let plan = debugReportPlan(sources: [
            source(.criticalLogs, "c1", size: 20, age: 1, treatment: .unchanged),
            source(.criticalLogs, "c2", size: 20, age: 2, treatment: .unchanged),
            source(.criticalLogs, "c3", size: 20, age: 3, treatment: .unchanged),
            source(.appLogs, "a1", size: 20, age: 1),
            source(.appLogs, "a2", size: 20, age: 2),
            source(.appLogs, "a3", size: 20, age: 3)
        ], limits: limits, now: now)
        XCTAssertEqual(plan.entries.map { $0.source.name }, ["c1", "c2", "c3", "a1", "a2"])
        XCTAssertEqual(plan.omitted.map(\.name), ["a3"])
    }

    func testAFreshLogIsKeptAheadOfAnOldLogOfAnEarlierSection() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: Double = 24 * 3600
        let limits = DebugReportLimits(totalBytes: 100, sectionBytes: 100, fileBytes: 100, criticalLogSectionBytes: 100)
        let plan = debugReportPlan(sources: [
            source(.criticalLogs, "old-critlog", size: 40, age: 10 * day, treatment: .unchanged),
            source(.appLogs, "old-app", size: 40, age: 8 * day),
            source(.notificationLogs, "new-nse", size: 40, age: 3600),
            source(.cpuProfiles, "new-profile", size: 40, age: 3600)
        ], limits: limits, now: now)
        XCTAssertEqual(Set(plan.entries.map { $0.source.name }), ["new-nse", "new-profile"])
        XCTAssertEqual(Set(plan.omitted.map(\.name)), ["old-critlog", "old-app"])
    }

    func testOldLogsStillFillTheRoomLeft() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: Double = 24 * 3600
        let limits = DebugReportLimits(totalBytes: 100, sectionBytes: 100, fileBytes: 100)
        let plan = debugReportPlan(sources: [
            source(.appLogs, "old-app-1", size: 30, age: 14 * day),
            source(.appLogs, "old-app-2", size: 30, age: 15 * day),
            source(.notificationLogs, "new-nse", size: 30, age: 3600)
        ], limits: limits, now: now)
        XCTAssertEqual(Set(plan.entries.map { $0.source.name }), ["old-app-1", "old-app-2", "new-nse"])
        XCTAssertTrue(plan.omitted.isEmpty)
        let appEntries = plan.entries.filter { $0.source.section == .appLogs }.map(\.entryName)
        XCTAssertEqual(appEntries, ["logs/app/old-app-1", "logs/app/old-app-2"], "newest first within the part")
    }

    func testCrashesCallsAndMetricKitAreNotHeldBackByAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: Double = 24 * 3600
        let limits = DebugReportLimits(totalBytes: 60, sectionBytes: 60, fileBytes: 60)
        let plan = debugReportPlan(sources: [
            source(.crashes, "old-crash", size: 20, age: 30 * day, treatment: .plainText),
            source(.callLogs, "old-call.log", size: 20, age: 30 * day),
            source(.metricKit, "old-metric.json", size: 20, age: 30 * day, treatment: .unchanged),
            source(.appLogs, "new-app", size: 20, age: 3600)
        ], limits: limits, now: now)
        XCTAssertEqual(Set(plan.entries.map { $0.source.name }), ["old-crash", "old-call.log", "old-metric.json"])
        XCTAssertEqual(plan.omitted.map(\.name), ["new-app"])
    }

    func testCrashFramesKeepTheirOffsets() throws {
        let line = "TelegramUIFramework 0x10a3b2c10 +45678901 [UUID]"
        let crash = DebugReportSource(section: .crashes, name: "crash.txt", text: line, treatment: .plainText, modified: Date())
        let plan = debugReportPlan(sources: [crash])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("report-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(debugReportArchive(plan: plan, manifest: "m", baseName: "r", in: directory))
        let unzipped = directory.appendingPathComponent("out", isDirectory: true)
        XCTAssertTrue(SSZipArchive.unzipFile(atPath: file.path, toDestination: unzipped.path))
        let text = try String(contentsOf: unzipped.appendingPathComponent("r/crashes/crash.txt"), encoding: .utf8)
        XCTAssertEqual(text, line)
    }

    func testInfoTextHasVersionDeviceExperimentsAndNoAccountDetails() {
        let info = DebugReportInfo(appVersion: "13.2", buildNumber: "202611140100", bundleId: "org.klaipher.Nanogram", osVersion: "iOS 26.1", deviceModelIdentifier: "iPhone15,2", deviceChip: "iPhone 14 Pro (A16), iPhone15,2", isMainApp: true, hasAccount: true, logToFile: true, redactSensitiveData: true, lowPowerMode: false, thermalState: "nominal", localeIdentifier: "en_US", experimentsReport: "Performance experiments (device iPhone15,2)\nthreadPoolQualityOfService=off")
        let text = debugReportInfoText(info)
        for part in ["13.2 (202611140100)", "iOS 26.1", "iPhone15,2", "Log to File: on", "Store build: yes", "Performance experiments (device iPhone15,2)", "threadPoolQualityOfService=off"] {
            XCTAssertTrue(text.contains(part), part)
        }
    }

    func testEnergyNumbersAreKeptEvenWhenTheCapsAreFull() {
        let limits = DebugReportLimits(totalBytes: 10, sectionBytes: 10, fileBytes: 10)
        let plan = debugReportPlan(sources: [
            source(.appLogs, "log", size: 10, age: 1),
            source(.energy, "energy.txt", size: 8, age: 1000)
        ], limits: limits)
        XCTAssertEqual(plan.entries.map { $0.entryName }, ["energy/energy.txt", "logs/app/log"])
        XCTAssertTrue(plan.omitted.isEmpty)
    }

    func testEnergyAndWatchComeRightAfterTheInfo() {
        let sections = DebugReportSection.allCases
        XCTAssertEqual(Array(sections.prefix(3)), [.info, .energy, .watch])
        XCTAssertEqual(DebugReportSection.energy.folder, "energy")
        XCTAssertEqual(DebugReportSection.watch.folder, "watch")
    }

    func testManifestCarriesTheWatchLine() {
        let plan = debugReportPlan(sources: [])
        let manifest = debugReportManifest(infoLines: ["App: x"], watchLine: "Apple Watch: no paired Apple Watch, so the report has no watch part.", plan: plan, created: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(manifest.contains("Apple Watch: no paired Apple Watch"))
        XCTAssertTrue(manifest.contains("Apple Watch part"))
        XCTAssertTrue(manifest.contains("watch/]: none on this device"))
    }

    func testWatchFilesLandUnderWatchWithTheirOwnManifest() {
        let created = Date(timeIntervalSince1970: 5)
        let sources = debugReportWatchSources(files: [WatchReportFile(name: "manifest.txt", text: "m"), WatchReportFile(name: "log.txt", text: "l")], created: created)
        let plan = debugReportPlan(sources: sources)
        XCTAssertEqual(Set(plan.entries.map { $0.entryName }), ["watch/manifest.txt", "watch/log.txt"])
    }

    func testNoteMentionsTheWatchAndTheEnergyNumbers() {
        XCTAssertTrue(debugReportPrivacyNote.contains("CPU and energy numbers"))
        XCTAssertTrue(debugReportPrivacyNote.contains("Apple Watch"))
    }
}
