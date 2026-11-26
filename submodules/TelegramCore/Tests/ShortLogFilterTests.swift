import Foundation
import XCTest
@testable import TelegramCore

/// The short log (`critlog-*.txt`, 1 MB per file, 20 files) was ~60% routine lines on a tester's device: msgsAck and
/// ping sends, every Postbox transaction over 10 ms, one hole-removal line per tag space and the cleanup's in-memory
/// size reports. A file filled in as little as 55 minutes. `ShortLogFilter` keeps those out of the short log (the full
/// log still has them), counts them, and writes the counts in one summary line every few minutes.
final class ShortLogFilterTests: XCTestCase {
    func testAcksAndPingsAreLeftOutAndCounted() {
        let filter = ShortLogFilter()
        XCTAssertFalse(filter.admitMTProto("[MTProto#0xe000001139e6140@0x200000113a56400 preparing msgsAck (7712233845514578944/0)]"))
        XCTAssertFalse(filter.admitMTProto("[MTProto#0xe000001139e6140@0x200000113a56400 preparing ping (7712233845514480640/0)]"))
        XCTAssertEqual(filter.counts, ShortLogFilter.Counts(msgsAck: 1, ping: 1))
    }

    func testOtherMTProtoLinesStay() {
        let filter = ShortLogFilter()
        // Containers map request ids to the container id that acks and bad_msg_notification refer to; file parts are
        // the evidence for a stalled download; a time-fix ping is rare.
        let kept = [
            "[MTProto#0x20000012a4156c0@0x200000113a56400 preparing upload.getFile (7712233915176162304/0)]",
            "    container (7712233845538077696) of (7712233845538008064), in 2972624493331132588",
            "[MTProto#0x1@0x2 sending time fix ping (7712233845514480640/0, 12)]",
            "[MTProto#0x1@0x2 preparing messages.setTyping (7712233845514480640/3)]",
            "[MTProto#0x1@0x2 preparing ping_delay_disconnect (7712233845514480640/0)]",
            "preparing msgsAck (1/0)",
        ]
        for line in kept {
            XCTAssertTrue(filter.admitMTProto(line), line)
        }
        XCTAssertEqual(filter.counts, ShortLogFilter.Counts())
    }

    func testTransactionMillisecondsAreParsed() {
        XCTAssertEqual(ShortLogFilter.transactionMilliseconds("Postbox transaction took 34.26694869995117 ms, from: submodules/TelegramCore/Sources/State/AccountViewTracker.swift:2384 keys: orderedItemList"), 34.26694869995117)
        XCTAssertEqual(ShortLogFilter.transactionMilliseconds("Postbox transaction took 120.5 ms, from: a.swift:1"), 120.5)
        XCTAssertNil(ShortLogFilter.transactionMilliseconds("Postbox transaction took abc ms, from: a.swift:1"))
        XCTAssertNil(ShortLogFilter.transactionMilliseconds("Postbox transaction took 12.0"))
        XCTAssertNil(ShortLogFilter.transactionMilliseconds("Postbox slow transaction (60.0 ms) live views: chatList=1"))
    }

    func testOnlySlowTransactionsReachTheShortLog() {
        let filter = ShortLogFilter()
        XCTAssertFalse(filter.admitPostbox("Postbox transaction took 12.13 ms, from: a.swift:8", now: 1000.0))
        XCTAssertFalse(filter.admitPostbox("Postbox transaction took 49.99 ms, from: a.swift:8", now: 1000.0))
        // 50 ms is where Postbox also logs the live views of a slow transaction: the two lines stay together.
        XCTAssertTrue(filter.admitPostbox("Postbox transaction took 50.0 ms, from: a.swift:8", now: 1000.0))
        XCTAssertTrue(filter.admitPostbox("Postbox transaction took 812.4 ms, from: a.swift:8", now: 1000.0))
        XCTAssertTrue(filter.admitPostbox("Postbox slow transaction (812.4 ms) live views: chatList=1", now: 1000.0))
        // A line that does not parse is kept.
        XCTAssertTrue(filter.admitPostbox("Postbox transaction took ? ms, from: a.swift:8", now: 1000.0))
        XCTAssertEqual(filter.counts, ShortLogFilter.Counts(fastTransactions: 2))
    }

    func testAHoleRemovalIsLoggedOnceForAllItsSpaces() {
        let filter = ShortLogFilter()
        let prefix = "MessageHistoryHoleIndexTable: removeInternal peerId: 2:Id(rawValue: 1099505434) namespace: 0 space: "
        XCTAssertTrue(filter.admitPostbox(prefix + ".everywhere range: 236257...236259", now: 1000.0))
        XCTAssertFalse(filter.admitPostbox(prefix + ".tag32 range: 236257...236259", now: 1000.001))
        XCTAssertFalse(filter.admitPostbox(prefix + ".tag2 range: 236257...236259", now: 1000.002))
        // Another range, another namespace or another peer is a new removal.
        XCTAssertTrue(filter.admitPostbox(prefix + ".tag2 range: 236260...236261", now: 1000.003))
        XCTAssertTrue(filter.admitPostbox("MessageHistoryHoleIndexTable: removeInternal peerId: 2:Id(rawValue: 1099505434) namespace: 1 space: .tag2 range: 236260...236261", now: 1000.004))
        XCTAssertTrue(filter.admitPostbox("MessageHistoryHoleIndexTable: removeInternal peerId: 2:Id(rawValue: 7) namespace: 1 space: .tag2 range: 236260...236261", now: 1000.005))
        XCTAssertEqual(filter.counts, ShortLogFilter.Counts(holeSpaces: 2))
    }

    func testTheSameHoleRemovedAgainLaterIsLoggedAgain() {
        let filter = ShortLogFilter()
        let line = "MessageHistoryHoleIndexTable: removeInternal peerId: 2:Id(rawValue: 5) namespace: 0 space: .everywhere range: 1...9"
        XCTAssertTrue(filter.admitPostbox(line, now: 1000.0))
        XCTAssertTrue(filter.admitPostbox(line, now: 1000.0 + ShortLogFilter.holeRepeatWindow + 0.1))
        // Any other line kept in between ends the run as well.
        XCTAssertTrue(filter.admitPostbox("Postbox transaction took 70.0 ms, from: a.swift:8", now: 1002.0))
        XCTAssertTrue(filter.admitPostbox(line, now: 1002.0))
        XCTAssertEqual(filter.counts, ShortLogFilter.Counts())
    }

    func testCleanupSizeReportsAreLeftOutButItsOtherLinesStay() {
        let filter = ShortLogFilter()
        XCTAssertFalse(filter.admitPostbox("TimeBasedCleanup in-memory size: 0 MB", now: 1000.0))
        XCTAssertTrue(filter.admitPostbox("TimeBasedCleanup: scan id: 42 finished", now: 1000.0))
        XCTAssertTrue(filter.admitPostbox("[TimeBasedCleanup] 1.5 s removed 3 short-lived files, 4 general files, 0 limit files", now: 1000.0))
        XCTAssertTrue(filter.admitPostbox("Did open DB at /tmp/db_sqlite", now: 1000.0))
        XCTAssertEqual(filter.counts, ShortLogFilter.Counts(cleanupSizeReports: 1))
    }

    func testTheSummaryComesEveryIntervalOnlyWhenSomethingWasLeftOut() {
        let filter = ShortLogFilter()
        // The first call starts the interval.
        XCTAssertNil(filter.takeSummary(now: 1000.0))
        XCTAssertFalse(filter.admitMTProto("[MTProto#0x1@0x2 preparing msgsAck (1/0)]"))
        XCTAssertFalse(filter.admitMTProto("[MTProto#0x1@0x2 preparing msgsAck (2/0)]"))
        XCTAssertFalse(filter.admitMTProto("[MTProto#0x1@0x2 preparing ping (3/0)]"))
        XCTAssertFalse(filter.admitPostbox("Postbox transaction took 11.0 ms, from: a.swift:8", now: 1001.0))
        XCTAssertFalse(filter.admitPostbox("TimeBasedCleanup in-memory size: 0 MB", now: 1001.0))
        XCTAssertNil(filter.takeSummary(now: 1000.0 + ShortLogFilter.summaryInterval - 1.0))
        XCTAssertEqual(filter.takeSummary(now: 1000.0 + ShortLogFilter.summaryInterval), "Short log left out in the last 300 s: msgsAck 2, ping 1, transactions under 50 ms 1, extra hole spaces 0, cleanup size reports 1")
        XCTAssertEqual(filter.counts, ShortLogFilter.Counts())
        // Nothing left out since: no line, but the interval starts again.
        XCTAssertNil(filter.takeSummary(now: 1000.0 + 2.0 * ShortLogFilter.summaryInterval))
        XCTAssertFalse(filter.admitMTProto("[MTProto#0x1@0x2 preparing ping (4/0)]"))
        XCTAssertNil(filter.takeSummary(now: 1000.0 + 2.5 * ShortLogFilter.summaryInterval))
        XCTAssertEqual(filter.takeSummary(now: 1000.0 + 3.0 * ShortLogFilter.summaryInterval), "Short log left out in the last 300 s: msgsAck 0, ping 1, transactions under 50 ms 0, extra hole spaces 0, cleanup size reports 0")
    }

    func testTheSummaryCoversTheWholeTimeSinceTheLastOne() {
        let filter = ShortLogFilter()
        XCTAssertNil(filter.takeSummary(now: 1000.0))
        XCTAssertFalse(filter.admitMTProto("[MTProto#0x1@0x2 preparing ping (4/0)]"))
        // The app was suspended: the next line comes long after the interval.
        XCTAssertEqual(filter.takeSummary(now: 1000.0 + 3600.0), "Short log left out in the last 3600 s: msgsAck 0, ping 1, transactions under 50 ms 0, extra hole spaces 0, cleanup size reports 0")
    }

    func testTheFilterIsSafeToUseFromSeveralThreads() {
        let filter = ShortLogFilter()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            for i in 0 ..< 1000 {
                let _ = filter.admitMTProto("[MTProto#0x1@0x2 preparing msgsAck (\(index * 1000 + i)/0)]")
                let _ = filter.admitPostbox("Postbox transaction took 11.0 ms, from: a.swift:8", now: 1000.0)
            }
        }
        XCTAssertEqual(filter.counts, ShortLogFilter.Counts(msgsAck: 8000, fastTransactions: 8000))
    }
}
