import Foundation
import XCTest
import SwiftSignalKit
@testable import TelegramCore

/// The app and the notification extension log for a while (data paths, database opens, the push token) before they
/// have read the stored "Log to File" setting. A logger created with `holdsFileLinesUntilConfigured` keeps those lines
/// in memory, and the first `logToFile` assignment decides: true writes them in order, false drops them. Before
/// this, Log to File off still wrote ~90 lines per app launch and ~30 per notification extension process.
final class LoggerHeldFileLinesTests: XCTestCase {
    private var basePath = ""

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "LoggerHeldFileLinesTests-" + UUID().uuidString
    }

    override func tearDown() {
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    // The app's Logger lives forever; its files must be released on its queue, so test loggers are never released.
    private static var loggers: [Logger] = []

    private func makeLogger(holds: Bool = true) -> Logger {
        let logger = Logger(rootPath: self.basePath, basePath: self.basePath + "/logs", holdsFileLinesUntilConfigured: holds)
        logger.logToConsole = false
        LoggerHeldFileLinesTests.loggers.append(logger)
        return logger
    }

    private func logFilePaths() -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: self.basePath + "/logs")) ?? []).filter { $0.hasPrefix("log-") }
        return names.sorted().map { self.basePath + "/logs/" + $0 }
    }

    private func lines() -> [String] {
        var result: [String] = []
        for path in self.logFilePaths() {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            result.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }
        return result
    }

    func testHeldLinesAreDroppedWhenTheSettingIsOff() {
        let logger = self.makeLogger()
        for i in 0 ..< 50 {
            logger.log("Test", "early line \(i)")
        }
        // Neither the flush paths nor collection write held lines: the setting is not known yet.
        logger.sync()
        XCTAssertEqual(self.logFilePaths(), [])

        logger.logToFile = false
        logger.log("Test", "late line")
        logger.sync()
        XCTAssertEqual(self.logFilePaths(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.basePath + "/logs"))
        XCTAssertEqual(logger.backlog.pendingBytes, 0)
    }

    func testHeldLinesAreWrittenInOrderWhenTheSettingIsOn() {
        let logger = self.makeLogger()
        for i in 0 ..< 20 {
            logger.log("Test", "early line \(i)")
        }
        logger.drainForTesting()
        XCTAssertGreaterThan(logger.backlog.pendingBytes, 0)
        logger.sync()
        XCTAssertEqual(self.logFilePaths(), [])

        logger.logToFile = true
        logger.log("Test", "late line")
        logger.sync()
        let lines = self.lines()
        XCTAssertEqual(lines.count, 21)
        for (index, line) in lines.prefix(20).enumerated() {
            XCTAssertTrue(line.hasPrefix("[Test] "), line)
            XCTAssertTrue(line.hasSuffix(" early line \(index)"), line)
        }
        XCTAssertTrue(lines.last?.hasSuffix(" late line") ?? false)
        XCTAssertEqual(logger.backlog.pendingBytes, 0)
    }

    func testTheHoldIsBoundedAndKeepsTheNewestLines() {
        let logger = self.makeLogger()
        logger.heldFileLinesLimit = 4 * 1024
        let payload = String(repeating: "z", count: 100)
        let count = 200
        for i in 0 ..< count {
            logger.log("Test", "\(i) \(payload)")
        }
        logger.drainForTesting()
        XCTAssertLessThanOrEqual(logger.backlog.pendingBytes, 4 * 1024)

        logger.logToFile = true
        logger.sync()
        let lines = self.lines()
        XCTAssertGreaterThan(lines.count, 1)
        // The first line says how many of the earliest lines were dropped; the rest are the newest, in order.
        guard let first = lines.first, let last = lines.last else {
            return
        }
        XCTAssertTrue(first.contains("[Logger] "), first)
        XCTAssertTrue(first.contains("lines logged before the settings were read were dropped"), first)
        XCTAssertTrue(last.hasSuffix(" \(count - 1) \(payload)"), last)
        let kept = lines.dropFirst()
        XCTAssertLessThan(kept.count, count)
        let firstKeptIndex = count - kept.count
        for (offset, line) in kept.enumerated() {
            XCTAssertTrue(line.hasSuffix(" \(firstKeptIndex + offset) \(payload)"), line)
        }
    }

    func testOnlyTheFirstAssignmentReleasesTheHold() {
        let logger = self.makeLogger()
        logger.log("Test", "early line")
        logger.logToFile = false
        logger.logToFile = true
        logger.log("Test", "after switching on")
        logger.sync()
        // The early line was dropped by the first assignment and is not written by the later one.
        let lines = self.lines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.hasSuffix(" after switching on") ?? false)
    }

    func testALoggerThatDoesNotHoldWritesAtOnceAsBefore() {
        let logger = self.makeLogger(holds: false)
        logger.log("Test", "line")
        logger.sync()
        XCTAssertEqual(self.lines().count, 1)
    }

    func testPushTokenSummaryNeverContainsTheWholeToken() {
        var bytes: [UInt8] = []
        for i in 0 ..< 32 {
            bytes.append(UInt8(truncatingIfNeeded: 0x10 + i))
        }
        let token = Data(bytes)
        let summary = Logger.pushTokenSummary(token)
        XCTAssertEqual(summary, "32 bytes, 10111213...")
        XCTAssertFalse(summary.contains("2f"))
        XCTAssertEqual(Logger.pushTokenSummary(Data()), "0 bytes")
        XCTAssertEqual(Logger.pushTokenSummary(Data([0xab, 0xcd])), "2 bytes")
    }
}
