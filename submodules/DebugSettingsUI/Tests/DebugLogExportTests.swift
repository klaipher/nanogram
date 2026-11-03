import XCTest
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

    /// The module's sources are bundled with the tests (`data` in BUILD). Only the shared export flow may pick a
    /// chat or send a message, and nothing may resolve a fixed username.
    func testNoExportUsesAFixedPeer() throws {
        let sources = try self.moduleSources()
        XCTAssertTrue(sources.keys.contains("DebugController.swift"))
        XCTAssertTrue(sources.keys.contains("CrashReportsController.swift"))
        XCTAssertTrue(sources.keys.contains("DebugLogExport.swift"))
        for (name, text) in sources {
            for forbidden in ["resolvePeerByName", "iOSCrashReportsBot", "PeerId(", "EnginePeer.Id(", "Via Telegram", "Telegram Logs", "Telegram Team"] {
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
