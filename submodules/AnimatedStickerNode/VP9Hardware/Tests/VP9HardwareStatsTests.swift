import Foundation
import XCTest
@testable import VP9Hardware

// The counters that say how often a sticker got a hardware decoder, and how often it did not because every session
// slot was taken. They decide whether the session cap (4 stickers with alpha) is why most stickers use libvpx.
final class VP9HardwareStatsTests: XCTestCase {
    func testOutcomesAreCounted() {
        let store = VP9HardwareStatsStore()
        store.record(.hardware)
        store.record(.hardware)
        store.record(.capReached)
        store.record(.sessionFailure)
        store.record(.ineligible)
        store.record(.ineligible)
        store.record(.ineligible)
        XCTAssertEqual(store.snapshot, VP9HardwareStats(hardwareStarts: 2, capMisses: 1, sessionFailures: 1, ineligible: 3, peakSessions: 0))
    }

    func testThePeakSessionCountOnlyGrows() {
        let store = VP9HardwareStatsStore()
        store.noteActiveSessions(2)
        store.noteActiveSessions(8)
        store.noteActiveSessions(4)
        XCTAssertEqual(store.snapshot.peakSessions, 8)
    }

    func testTheSessionCounterTracksItsPeak() {
        let counter = VP9HardwareDecoding.SessionCounter()
        XCTAssertTrue(counter.acquire(2, limit: 8))
        XCTAssertTrue(counter.acquire(2, limit: 8))
        counter.release(2)
        XCTAssertFalse(counter.acquire(8, limit: 8))
        XCTAssertEqual(counter.current, 2)
        XCTAssertEqual(counter.peak, 4)
    }

    func testAReportIsDueOncePerMinuteAndOnlyWhenSomethingHappened() {
        let store = VP9HardwareStatsStore()
        XCTAssertNil(store.takeReport(now: 1000.0))
        store.record(.capReached)
        let first = store.takeReport(now: 1000.0)
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.contains("capMisses=1") == true, first ?? "")
        store.record(.capReached)
        XCTAssertNil(store.takeReport(now: 1030.0), "less than a minute after the last report")
        let second = store.takeReport(now: 1060.0)
        XCTAssertTrue(second?.contains("capMisses=2") == true, second ?? "")
        XCTAssertNil(store.takeReport(now: 1200.0), "nothing new since the last report")
    }

    func testAClockGoingBackwardsDoesNotSilenceTheReport() {
        let store = VP9HardwareStatsStore()
        store.record(.hardware)
        XCTAssertNotNil(store.takeReport(now: 5000.0))
        store.record(.hardware)
        XCTAssertNotNil(store.takeReport(now: 100.0))
    }
}
