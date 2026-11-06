import Foundation
import XCTest
import SwiftSignalKit
import DiskWriteAccounting
@testable import TelegramCore

/// "Log to File" used to cost one write() per line (hundreds of thousands a day on a device). Lines are now
/// buffered on the logger queue and written in batches. These tests pin that the files stay byte-identical to the
/// unbuffered version and that every flush trigger writes everything. The flush timer is a manual clock, nothing
/// sleeps.
final class LoggerBufferedLogTests: XCTestCase {
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var scheduledItems: [(Double, () -> Void)] = []

        var delays: [Double] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.scheduledItems.map { $0.0 }
        }

        func schedule(_ delay: Double, _ f: @escaping () -> Void) {
            self.lock.lock()
            self.scheduledItems.append((delay, f))
            self.lock.unlock()
        }

        /// Fires every scheduled timer (the logger hops to its own queue).
        func fireAll() {
            self.lock.lock()
            let items = self.scheduledItems
            self.scheduledItems = []
            self.lock.unlock()
            for (_, f) in items {
                f()
            }
        }
    }

    private final class WriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Int] = []

        func add(_ size: Int) {
            self.lock.lock()
            self.sizes.append(size)
            self.lock.unlock()
        }

        var count: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.sizes.count
        }

        var total: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.sizes.reduce(0, +)
        }
    }

    private var basePath: String!
    private var clock: ManualClock!
    private var writes: WriteCounter!

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "LoggerBufferedLogTests-" + UUID().uuidString
        self.clock = ManualClock()
        self.writes = WriteCounter()
    }

    override func tearDown() {
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    // The app's Logger lives forever; its files must be released on its queue, so test loggers are never released.
    private static var loggers: [Logger] = []

    private func makeLogger(logToFile: Bool = true) -> Logger {
        let logger = Logger(rootPath: self.basePath, basePath: self.basePath + "/logs")
        logger.logToFile = logToFile
        logger.logToConsole = false
        let clock = self.clock!
        let writes = self.writes!
        logger.scheduleLogFlush = { delay, f in
            clock.schedule(delay, f)
        }
        logger.onLogWrite = { size in
            writes.add(size)
        }
        LoggerBufferedLogTests.loggers.append(logger)
        return logger
    }

    private func logFilePaths() -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: self.basePath + "/logs")) ?? []).filter { $0.hasPrefix("log-") }
        return names.sorted().map { self.basePath + "/logs/" + $0 }
    }

    private func bytes(of path: String) -> Int {
        var value = stat()
        return stat(path, &value) == 0 ? Int(value.st_size) : 0
    }

    private func logFileBytes() -> Int {
        return self.logFilePaths().reduce(0, { $0 + self.bytes(of: $1) })
    }

    private func collect(_ logger: Logger) -> [(String, String)] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [(String, String)] = []
        let disposable = logger.collectLogs().start(next: { value in
            result = value
            semaphore.signal()
        })
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10.0), .success)
        disposable.dispose()
        return result
    }

    private func lines(in paths: [String]) -> [String] {
        var result: [String] = []
        for path in paths {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            XCTAssertTrue(text.isEmpty || text.hasSuffix("\n"), "file ends in the middle of a line")
            result.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }
        return result
    }

    private func assertLine(_ line: String, tag: String, text: String, file: StaticString = #filePath, line lineNumber: UInt = #line) {
        let pattern = "^\\[" + NSRegularExpression.escapedPattern(for: tag) + "\\] \\d+-\\d+-\\d+ \\d\\d:\\d\\d:\\d\\d\\.\\d\\d\\d " + NSRegularExpression.escapedPattern(for: text) + "$"
        XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), "unexpected line: \(line)", file: file, line: lineNumber)
    }

    func testLinesAreWrittenInOrderWithTheOldFormat() {
        let logger = self.makeLogger()
        for i in 0 ..< 300 {
            logger.log("Test", "line \(i)")
        }
        logger.sync()
        let lines = self.lines(in: self.logFilePaths())
        XCTAssertEqual(lines.count, 300)
        for (index, line) in lines.enumerated() {
            self.assertLine(line, tag: "Test", text: "line \(index)")
        }
        // Byte for byte: every line plus its newline, nothing else.
        XCTAssertEqual(self.logFileBytes(), lines.reduce(0, { $0 + $1.utf8.count + 1 }))
    }

    func testLinesWaitForTheTimerAndAreWrittenByOneWrite() {
        let logger = self.makeLogger()
        for i in 0 ..< 50 {
            logger.log("Test", "line \(i)")
        }
        logger.drainForTesting()
        XCTAssertEqual(self.writes.count, 0)
        XCTAssertEqual(self.logFileBytes(), 0)
        // One timer for the whole batch, 1 s after the first line.
        XCTAssertEqual(self.clock.delays, [1.0])

        self.clock.fireAll()
        logger.drainForTesting()
        XCTAssertEqual(self.writes.count, 1)
        XCTAssertEqual(self.lines(in: self.logFilePaths()).count, 50)
        XCTAssertEqual(self.writes.total, self.logFileBytes())
    }

    func testNoTimerRunsWhileIdle() {
        let logger = self.makeLogger()
        logger.log("Test", "one")
        logger.drainForTesting()
        self.clock.fireAll()
        logger.drainForTesting()
        XCTAssertEqual(self.clock.delays, [])
        // The next line after an idle flush arms exactly one new timer.
        logger.log("Test", "two")
        logger.log("Test", "three")
        logger.drainForTesting()
        XCTAssertEqual(self.clock.delays, [1.0])
    }

    func testA64KBBurstFlushesWithoutWaitingForTheTimer() {
        let logger = self.makeLogger()
        let payload = String(repeating: "x", count: 1000)
        for i in 0 ..< 100 {
            logger.log("Test", "\(i) \(payload)")
        }
        logger.drainForTesting()
        // 100 lines of ~1 KB: one write at 64 KB, the rest still buffered.
        XCTAssertEqual(self.writes.count, 1)
        XCTAssertGreaterThanOrEqual(self.writes.total, 64 * 1024)
        XCTAssertLessThan(self.writes.total, 64 * 1024 + 2048)
        XCTAssertEqual(self.logFileBytes(), self.writes.total)
        XCTAssertEqual(self.clock.delays.count, 1)

        logger.sync()
        let lines = self.lines(in: self.logFilePaths())
        XCTAssertEqual(lines.count, 100)
        for (index, line) in lines.enumerated() {
            self.assertLine(line, tag: "Test", text: "\(index) \(payload)")
        }
    }

    func testSyncAndFlushPendingLogsWriteEverything() {
        let logger = self.makeLogger()
        logger.log("Test", "before sync")
        logger.sync()
        XCTAssertEqual(self.lines(in: self.logFilePaths()).count, 1)
        logger.log("Test", "before flush")
        logger.flushPendingLogsAndWait()
        XCTAssertEqual(self.lines(in: self.logFilePaths()).count, 2)
        logger.log("Test", "before async flush")
        logger.flushPendingLogs()
        logger.drainForTesting()
        XCTAssertEqual(self.lines(in: self.logFilePaths()).count, 3)
    }

    func testCollectLogsReturnsEverythingLoggedBeforeTheCall() {
        let logger = self.makeLogger()
        for i in 0 ..< 20 {
            logger.log("Test", "line \(i)")
        }
        // No flush and no timer: the export itself must flush.
        let files = self.collect(logger)
        XCTAssertEqual(files.count, 1)
        let lines = self.lines(in: files.map { $0.1 })
        XCTAssertEqual(lines.count, 20)
        XCTAssertEqual(self.writes.count, 1)
    }

    func testRotationFlushesTheOldFileFirstAndKeepsOrder() {
        let logger = self.makeLogger()
        // Files rotate at 2 MB: ~2.4 MB needs a second file.
        let payload = String(repeating: "y", count: 1000)
        let count = 2400
        for i in 0 ..< count {
            logger.log("Test", "\(i) \(payload)")
        }
        logger.sync()
        let paths = self.collect(logger).map { $0.1 }
        XCTAssertGreaterThanOrEqual(paths.count, 2)
        // The old file is complete (no line split, nothing pending for it) and holds the first lines.
        XCTAssertGreaterThanOrEqual(self.bytes(of: paths[0]), 2 * 1024 * 1024)
        let lines = self.lines(in: paths)
        XCTAssertEqual(lines.count, count)
        for (index, line) in lines.enumerated() {
            self.assertLine(line, tag: "Test", text: "\(index) \(payload)")
        }
    }

    func testNothingIsBufferedWhenLoggingToFileIsOff() {
        let logger = self.makeLogger(logToFile: false)
        for i in 0 ..< 100 {
            logger.log("Test", "line \(i)")
        }
        logger.drainForTesting()
        XCTAssertEqual(self.clock.delays, [])
        XCTAssertEqual(self.writes.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.basePath + "/logs"))
    }

    func testSwitchingFileLoggingOffWritesWhatIsBuffered() {
        let logger = self.makeLogger()
        logger.log("Test", "last line")
        logger.logToFile = false
        logger.log("Test", "not logged")
        logger.drainForTesting()
        let lines = self.lines(in: self.logFilePaths())
        XCTAssertEqual(lines.count, 1)
        if let line = lines.first {
            self.assertLine(line, tag: "Test", text: "last line")
        }
    }

    func testWriteCountDropsAndTheBytesAreStillCounted() {
        let before = DiskWriteAccounting.shared.bytesWritten(DiskWriteCategory.logs)
        let logger = self.makeLogger()
        let total = 2000
        for i in 0 ..< total {
            logger.log("Test", "a typical log line with some text \(i)")
        }
        logger.sync()
        // The old code made 2 write() calls per line; the batch needs a handful.
        XCTAssertLessThan(self.writes.count, 10)
        XCTAssertEqual(self.lines(in: self.logFilePaths()).count, total)
        XCTAssertEqual(self.writes.total, self.logFileBytes())
        // Other loggers in the process may add to the category too, never less than this one wrote.
        XCTAssertGreaterThanOrEqual(DiskWriteAccounting.shared.bytesWritten(DiskWriteCategory.logs) - before, Int64(self.writes.total))
    }
}
