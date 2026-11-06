import XCTest
import SwiftSignalKit
import ZipArchive
@testable import DebugSettingsUI

/// Every log, report and diagnostics export in Debug Settings goes through one flow that lets the user pick the
/// destination. These pin the names it shows and writes, and that no export is tied to a fixed chat or bot.
final class DebugLogExportTests: XCTestCase {
    private let version = "13.1.2"
    private let build = "202611031553"

    func testLogsSpec() {
        let spec = debugLogExportSpec(.logs, appVersion: self.version, buildNumber: self.build)
        XCTAssertEqual(spec.what, "Logs")
        XCTAssertEqual(spec.sheetTitle, "Send Logs")
        XCTAssertEqual(spec.subject, "Nanogram iOS logs (13.1.2 (202611031553))")
        XCTAssertEqual(spec.fileBaseName, "nanogram-logs-full")
        XCTAssertNil(spec.note)
    }

    func testEveryKindIsNamedNanogram() {
        var baseNames = Set<String>()
        for kind in DebugLogExportKind.allCases {
            let spec = debugLogExportSpec(kind, appVersion: self.version, buildNumber: self.build)
            XCTAssertEqual(spec.sheetTitle, "Send \(spec.what)", "\(kind)")
            XCTAssertTrue(spec.subject.hasPrefix("Nanogram iOS "), "\(kind): \(spec.subject)")
            XCTAssertTrue(spec.subject.hasSuffix(" (13.1.2 (202611031553))"), "\(kind): \(spec.subject)")
            XCTAssertTrue(spec.fileBaseName.hasPrefix("nanogram-logs-"), "\(kind): \(spec.fileBaseName)")
            XCTAssertEqual(spec.fileBaseName, spec.fileBaseName.lowercased(), "\(kind)")
            XCTAssertFalse(spec.fileBaseName.contains(" "), "\(kind)")
            for text in [spec.what, spec.sheetTitle, spec.subject, spec.fileBaseName, spec.note ?? ""] {
                XCTAssertFalse(text.lowercased().contains("telegram"), "\(kind): \(text)")
            }
            baseNames.insert(spec.fileBaseName)
        }
        XCTAssertEqual(baseNames.count, DebugLogExportKind.allCases.count)
    }

    func testEveryKindOffersEveryDestination() {
        XCTAssertEqual(debugLogExportDestinations(canSendInApp: true), [.nanogram, .email, .otherApps])
        // Without an account (or outside the main app) there is no chat to pick, but the files still leave.
        XCTAssertEqual(debugLogExportDestinations(canSendInApp: false), [.email, .otherApps])
        XCTAssertEqual(DebugLogExportDestination.allCases.map(\.title), ["Via Nanogram…", "Via Email…", "Other Apps…"])
    }

    func testConcatenatedArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.log")
        let second = directory.appendingPathComponent("b.log")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let logs = [("a.log", first.path), ("b.log", second.path)]

        let text = String(decoding: debugLogConcatenatedData(logs: logs, additionalInfo: "extra"), as: UTF8.self)
        XCTAssertEqual(text, "------ File: a.log ------\nfirst\n\n------ File: b.log ------\nsecond------ Additional Info ------\nextra")

        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let archive = try XCTUnwrap(debugLogConcatenatedArchive(logs: logs, baseName: "nanogram-logs-full", in: output))
        XCTAssertEqual(archive.name, "nanogram-logs-full.zip")
        XCTAssertEqual(archive.mimeType, "application/zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        // The joined text is only inside the archive.
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("nanogram-logs-full.txt").path))

        let copied = debugLogCopiedFiles(logs: logs, baseName: "nanogram-logs-critical", mimeType: "text/plain", in: output)
        XCTAssertEqual(copied.map(\.name), ["nanogram-logs-critical-a.log", "nanogram-logs-critical-b.log"])
    }

    func testOnlyTheCrashLogAsksBeforeSendingToAChat() {
        for kind in DebugLogExportKind.allCases {
            let spec = debugLogExportSpec(kind, appVersion: self.version, buildNumber: self.build)
            XCTAssertEqual(spec.confirmsChatSend, kind == .crashReport, "\(kind)")
            XCTAssertEqual(spec.failureNote != nil, kind == .crashReport, "\(kind)")
        }
        let crash = debugLogExportSpec(.crashReport, appVersion: self.version, buildNumber: self.build)
        XCTAssertEqual(crash.failureNote, "The log remains saved on this device.")
    }

    /// MetricKit reports are JSON; they go into the archive byte for byte, under their own names, not joined into text.
    func testFilesArchiveKeepsEachJSONReport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = directory.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let first = reports.appendingPathComponent("metric-1.json")
        let second = reports.appendingPathComponent("diagnostic-2.json")
        let firstData = Data(#"{"cpuMetrics":{"cumulativeCPUTime":"12 sec"}}"#.utf8)
        let secondData = Data(#"{"crashDiagnostics":[{"exceptionType":1}]}"#.utf8)
        try firstData.write(to: first)
        try secondData.write(to: second)

        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let archive = try XCTUnwrap(debugLogFilesArchive(logs: [("metric-1.json", first.path), ("diagnostic-2.json", second.path)], baseName: "nanogram-logs-metrickit", in: output))
        XCTAssertEqual(archive.name, "nanogram-logs-metrickit.zip")
        XCTAssertEqual(archive.mimeType, "application/zip")
        // Only the archive is left in the export directory; the stored reports are untouched.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["nanogram-logs-metrickit.zip"])
        XCTAssertEqual(try Data(contentsOf: first), firstData)

        let unzipped = directory.appendingPathComponent("unzipped", isDirectory: true)
        XCTAssertTrue(SSZipArchive.unzipFile(atPath: archive.path, toDestination: unzipped.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: unzipped.path)), ["metric-1.json", "diagnostic-2.json"])
        XCTAssertEqual(try Data(contentsOf: unzipped.appendingPathComponent("metric-1.json")), firstData)
        XCTAssertEqual(try Data(contentsOf: unzipped.appendingPathComponent("diagnostic-2.json")), secondData)

        XCTAssertNil(debugLogFilesArchive(logs: [], baseName: "nanogram-logs-metrickit", in: output))
    }

    /// The prepared files reach the export before its completion. On a concurrent queue the completion overtook the
    /// files while they were being zipped, and the export reported "nothing to send" with dozens of MetricKit reports.
    func testPreparedFilesArriveBeforeTheCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let reports = directory.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var logs: [(String, String)] = []
        for index in 0 ..< 40 {
            let url = reports.appendingPathComponent("metrics-\(index)-0.json")
            try Data(repeating: UInt8(ascii: "a"), count: 32 * 1024).write(to: url)
            logs.append((url.lastPathComponent, url.path))
        }
        let spec = debugLogExportSpec(.metricKitReports, appVersion: self.version, buildNumber: self.build)
        for round in 0 ..< 10 {
            let output = directory.appendingPathComponent("out-\(round)", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let lock = NSLock()
            var events: [String] = []
            let done = self.expectation(description: "completed \(round)")
            let _ = debugLogFilesArchiveSignal(.single(logs))(output, spec).start(next: { files in
                lock.lock()
                events.append("files:\(files.count)")
                lock.unlock()
            }, completed: {
                lock.lock()
                events.append("completed")
                lock.unlock()
                done.fulfill()
            })
            self.wait(for: [done], timeout: 30.0)
            Thread.sleep(forTimeInterval: 0.2)
            lock.lock()
            XCTAssertEqual(events, ["files:1", "completed"], "round \(round)")
            lock.unlock()
        }
    }

    func testMetricKitExportDeliversTheArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var logs: [(String, String)] = []
        for index in 0 ..< 40 {
            let url = directory.appendingPathComponent("metrics-\(index)-0.json")
            try Data(repeating: UInt8(ascii: "b"), count: 32 * 1024).write(to: url)
            logs.append((url.lastPathComponent, url.path))
        }
        let gate = DebugLogExportGate()
        let spec = debugLogExportSpec(.metricKitReports, appVersion: self.version, buildNumber: self.build)
        let delivered = self.expectation(description: "delivered")
        var deliveredFiles: [DebugLogExportFile] = []
        XCTAssertTrue(runDebugLogExport(gate: gate, spec: spec, prepare: debugLogFilesArchiveSignal(.single(logs)), showProgress: { {} }, nothingToSend: {
            XCTFail("nothing to send")
            delivered.fulfill()
        }, deliver: { files, exportDirectory, finish in
            deliveredFiles = files
            finish()
            try? FileManager.default.removeItem(at: exportDirectory)
            delivered.fulfill()
        }))
        self.wait(for: [delivered], timeout: 30.0)
        XCTAssertEqual(deliveredFiles.map(\.name), ["nanogram-logs-metrickit.zip"])
        XCTAssertFalse(gate.isRunning)
    }

    /// 1:1 call logs are named "<call id>_<time>.log" (plus a rotated ".log.1" and a ".log.json" stats file), so the
    /// "log-" collector never saw them. The export takes the logs of the newest calls, the rotated half with its log.
    func testCallLogFilesAreTheNewestCallsLogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["1_100.log", "1_100.log.1", "1_100.log.json", "2_200.log", "3_300.log", "notes.txt", "log-2026.txt"]
        for (index, name) in names.enumerated() {
            let url = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))], ofItemAtPath: url.path)
        }
        let all = debugCallLogFiles(in: directory.path, limit: 10)
        XCTAssertEqual(all.map { $0.0 }, ["3_300.log", "2_200.log", "1_100.log", "1_100.log.1"])
        let newest = debugCallLogFiles(in: directory.path, limit: 2)
        XCTAssertEqual(newest.map { $0.0 }, ["3_300.log", "2_200.log"])
        XCTAssertTrue(debugCallLogFiles(in: directory.appendingPathComponent("missing").path, limit: 10).isEmpty)
    }

    func testGateLetsOneExportRunAtATime() {
        let gate = DebugLogExportGate()
        XCTAssertFalse(gate.isRunning)
        let first = gate.begin()
        XCTAssertNotNil(first)
        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.isRunning)
        gate.end(first!)
        XCTAssertFalse(gate.isRunning)
        let second = gate.begin()
        XCTAssertNotNil(second)
        // A finished run's token cannot end a later one.
        gate.end(first!)
        XCTAssertTrue(gate.isRunning)
        gate.end(second!)
        XCTAssertFalse(gate.isRunning)
    }

    /// A repeat tap while the files are being prepared (or handed over) starts nothing: no second overlay, no
    /// second preparation.
    func testRepeatExportIsIgnoredUntilTheFirstIsDelivered() throws {
        let gate = DebugLogExportGate()
        let spec = debugLogExportSpec(.allLogs, appVersion: self.version, buildNumber: self.build)
        var preparations = 0
        var progressShown = 0
        var progressHidden = 0
        var subscribers: [Subscriber<[DebugLogExportFile], NoError>] = []
        let prepare: (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError> = { _, _ in
            preparations += 1
            return Signal { subscriber in
                subscribers.append(subscriber)
                return EmptyDisposable
            }
        }
        var delivered: [(files: [DebugLogExportFile], directory: URL, finish: () -> Void)] = []
        let run: () -> Bool = {
            return runDebugLogExport(gate: gate, spec: spec, prepare: prepare, showProgress: {
                progressShown += 1
                return { progressHidden += 1 }
            }, nothingToSend: {
                XCTFail("nothing to send")
            }, deliver: { files, directory, finish in
                delivered.append((files, directory, finish))
            })
        }

        XCTAssertTrue(run())
        XCTAssertFalse(run())
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(progressShown, 1)
        XCTAssertEqual(progressHidden, 0)

        let file = DebugLogExportFile(name: "nanogram-logs-all.zip", path: "/nonexistent/nanogram-logs-all.zip", mimeType: "application/zip")
        subscribers[0].putNext([file])
        subscribers[0].putCompletion()
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].files, [file])
        XCTAssertEqual(progressHidden, 1)
        // Still being handed over.
        XCTAssertFalse(run())

        delivered[0].finish()
        try? FileManager.default.removeItem(at: delivered[0].directory)
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(run())
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(progressShown, 2)
    }

    func testExportWithNoFilesEndsTheRunAndRemovesItsDirectory() {
        let gate = DebugLogExportGate()
        let spec = debugLogExportSpec(.storageStats, appVersion: self.version, buildNumber: self.build)
        var directory: URL?
        var nothingToSend = 0
        var progressHidden = 0
        XCTAssertTrue(runDebugLogExport(gate: gate, spec: spec, prepare: { url, _ in
            directory = url
            return .single([])
        }, showProgress: {
            return { progressHidden += 1 }
        }, nothingToSend: {
            nothingToSend += 1
        }, deliver: { _, _, _ in
            XCTFail("delivered nothing")
        }))
        XCTAssertEqual(nothingToSend, 1)
        XCTAssertEqual(progressHidden, 1)
        XCTAssertFalse(gate.isRunning)
        XCTAssertNotNil(directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory?.path ?? "/"))

        // A preparation that completes without files counts as nothing to send too.
        XCTAssertTrue(runDebugLogExport(gate: gate, spec: spec, prepare: { _, _ in .complete() }, showProgress: { {} }, nothingToSend: {
            nothingToSend += 1
        }, deliver: { _, _, _ in
            XCTFail("delivered nothing")
        }))
        XCTAssertEqual(nothingToSend, 2)
        XCTAssertFalse(gate.isRunning)
    }

    /// A share extension cancelled inside the sheet (Mail, Notes…) reports `completed == false` with its activity
    /// type while the sheet stays open; the files are still offered, so only completion or dismissal removes them.
    func testShareSheetKeepsTheExportWhileAnActivityIsCancelled() {
        XCTAssertFalse(debugLogShareSheetRemovesExport(completed: false, activityType: .mail))
        XCTAssertTrue(debugLogShareSheetRemovesExport(completed: true, activityType: .mail))
        XCTAssertTrue(debugLogShareSheetRemovesExport(completed: false, activityType: nil))
    }

    /// A failed message can be retried from the chat, and the retry reads the file again; the directory goes once
    /// every message is sent or deleted, or the upload has already taken a failed message's file.
    func testChatUploadKeepsTheFilesOfAFailedMessageThatCanBeRetried() {
        XCTAssertFalse(debugLogChatUploadsSettled([.failed(fileExists: true)]))
        XCTAssertFalse(debugLogChatUploadsSettled([.sent, .failed(fileExists: true)]))
        XCTAssertFalse(debugLogChatUploadsSettled([.sent, .sending]))
        XCTAssertTrue(debugLogChatUploadsSettled([.failed(fileExists: false)]))
        XCTAssertTrue(debugLogChatUploadsSettled([.sent, .gone]))
    }

    /// Mail attachments are read off the main queue; the composer is built with them on the main queue.
    func testMailAttachmentsAreReadOffTheMainQueue() throws {
        let files = [
            DebugLogExportFile(name: "a.txt", path: "/a", mimeType: "text/plain"),
            DebugLogExportFile(name: "b.zip", path: "/b", mimeType: "application/zip"),
            DebugLogExportFile(name: "c.zip", path: "/missing", mimeType: "application/zip")
        ]
        var readOnMain: [Bool] = []
        let lock = NSLock()
        let done = self.expectation(description: "loaded")
        loadDebugLogMailAttachments(files: files, read: { path in
            lock.lock()
            readOnMain.append(Thread.isMainThread)
            lock.unlock()
            return path == "/missing" ? nil : Data(path.utf8)
        }, completion: { attachments in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(attachments.map(\.fileName), ["a.txt", "b.zip"])
            XCTAssertEqual(attachments.map(\.mimeType), ["text/plain", "application/zip"])
            XCTAssertEqual(attachments.map(\.data), [Data("/a".utf8), Data("/b".utf8)])
            done.fulfill()
        })
        self.wait(for: [done], timeout: 5.0)
        XCTAssertEqual(readOnMain, [false, false, false])
    }

    /// The module's sources are bundled with the tests (`data` in BUILD). Only the shared export flow may pick a
    /// chat or send a message, and nothing may resolve a fixed username.
    func testNoExportUsesAFixedPeer() throws {
        let sources = try self.moduleSources()
        XCTAssertTrue(sources.keys.contains("DebugController.swift"))
        XCTAssertTrue(sources.keys.contains("CrashReportsController.swift"))
        XCTAssertTrue(sources.keys.contains("DebugLogExport.swift"))
        for (name, text) in sources {
            for forbidden in ["resolvePeerByName", "iOSCrashReportsBot", "PeerId(", "EnginePeer.Id(", "Via Telegram", "Telegram Logs", "Telegram Team", "help us", "helping make"] {
                XCTAssertFalse(text.contains(forbidden), "\(name) contains \(forbidden)")
            }
            if name != "DebugLogExport.swift" {
                for sending in ["enqueueMessages(", "makePeerSelectionController(", "MFMailComposeViewController(", "UIActivityViewController("] {
                    XCTAssertFalse(text.contains(sending), "\(name) sends on its own (\(sending)); use presentDebugLogExport")
                }
            }
        }
    }

    private func moduleSources() throws -> [String: String] {
        let bundle = Bundle(for: DebugLogExportTests.self)
        let root = try XCTUnwrap(bundle.resourceURL)
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift", !url.lastPathComponent.hasSuffix("Tests.swift") {
                result[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return result
    }
}
