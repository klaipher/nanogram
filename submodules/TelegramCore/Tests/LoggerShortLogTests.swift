import Foundation
import XCTest
import SwiftSignalKit
@testable import TelegramCore

/// The short log (`critlog-*.txt`) is written in every build, whatever "Log to File" says: it is
/// the small always-on log of MTProto and Postbox events. On device it cost ~0.3 s of write()
/// per session because every entry was its own write. Entries are now batched; these tests pin
/// that nothing is lost or reordered and that sync() and collection see everything.
final class LoggerShortLogTests: XCTestCase {
    private var basePath: String!

    override func setUp() {
        super.setUp()
        self.basePath = NSTemporaryDirectory() + "LoggerShortLogTests-" + UUID().uuidString
    }

    override func tearDown() {
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    // The app's Logger lives forever; its files must be released on its queue, so test
    // loggers are never released either.
    private static var loggers: [Logger] = []

    private func makeLogger() -> Logger {
        let logger = Logger(rootPath: self.basePath, basePath: self.basePath + "/logs")
        logger.logToFile = false
        logger.logToConsole = false
        LoggerShortLogTests.loggers.append(logger)
        return logger
    }

    private func collectShortLog(_ logger: Logger) -> [(Double, String)] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [(Double, String)] = []
        let disposable = logger.collectShortLog().start(next: { value in
            result = value
            semaphore.signal()
        })
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10.0), .success)
        disposable.dispose()
        return result
    }

    private func shortLogFileBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: self.basePath + "/logs")) ?? []
        var total = 0
        for name in files where name.hasPrefix("critlog-") {
            var value = stat()
            if stat(self.basePath + "/logs/" + name, &value) == 0 {
                total += Int(value.st_size)
            }
        }
        return total
    }

    func testEveryShortLogEntryIsCollectedInOrder() {
        let logger = self.makeLogger()
        for i in 0 ..< 500 {
            logger.shortLog("Test", "entry \(i)")
        }
        let events = self.collectShortLog(logger)
        // collectShortLog returns the newest 1000 events, newest first.
        XCTAssertEqual(events.count, 500)
        XCTAssertEqual(events.first?.1, "entry 499")
        XCTAssertEqual(events.last?.1, "entry 0")
        for (index, event) in events.reversed().enumerated() {
            XCTAssertEqual(event.1, "entry \(index)")
        }
    }

    func testSyncPutsEveryEntryOnDisk() {
        let logger = self.makeLogger()
        var expectedBytes = 0
        for i in 0 ..< 200 {
            let text = "sync entry \(i)"
            expectedBytes += 8 + 4 + 8 + text.utf8.count
            logger.shortLog("Test", text)
        }
        logger.sync()
        XCTAssertEqual(self.shortLogFileBytes(), expectedBytes)
    }

    func testEntriesReachTheDiskWithoutAnExplicitSync() {
        let logger = self.makeLogger()
        logger.shortLog("Test", "lonely entry")
        let expectedBytes = 8 + 4 + 8 + "lonely entry".utf8.count
        let deadline = Date().addingTimeInterval(5.0)
        while self.shortLogFileBytes() < expectedBytes, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(self.shortLogFileBytes(), expectedBytes)
    }

    func testTheShortLogRotatesIntoANewFileWithoutLosingEntries() {
        let logger = self.makeLogger()
        // 1 MB per file: ~1.3 MB of entries needs a second file.
        let payload = String(repeating: "x", count: 1000)
        for i in 0 ..< 1300 {
            logger.shortLog("Test", "\(i) \(payload)")
        }
        logger.sync()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: self.basePath + "/logs")) ?? []).filter { $0.hasPrefix("critlog-") }
        XCTAssertGreaterThanOrEqual(files.count, 2)
        XCTAssertEqual(self.shortLogFileBytes(), 1300 * (8 + 4 + 8 + payload.utf8.count) + (0 ..< 1300).reduce(0, { $0 + "\($1) ".utf8.count }))
    }

    func testBenchmarkShortLogThroughput() {
        let count = 20_000
        var results: [String] = []
        for (label, flushSize) in [("one write per entry (old)", 1), ("batched", 32 * 1024)] {
            let logger = self.makeLogger()
            logger.shortLogFlushSize = flushSize
            logger.shortLog("Test", "warm up")
            logger.sync()
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0 ..< count {
                logger.shortLog("Api", "[MTProto#0x1@0x2 preparing request \(i) (12345678)]")
            }
            logger.sync()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            results.append("\(label) \(String(format: "%.1f", elapsed * 1000)) ms")
            let _ = try? FileManager.default.removeItem(atPath: self.basePath + "/logs")
        }
        print("BENCH shortLog x\(count) incl. writing to disk: " + results.joined(separator: ", "))
    }
}
