import Foundation
import XCTest
@testable import Postbox

final class TransactionWriteAttributionTests: XCTestCase {
    func testSiteNameKeepsTheFileNameAndLine() {
        XCTAssertEqual(TransactionWriteAttribution.siteName(file: "/a/b/Postbox.swift", line: 42), "Postbox.swift:42")
        XCTAssertEqual(TransactionWriteAttribution.siteName(file: "Plain.swift", line: 1), "Plain.swift:1")
    }

    func testTransactionsThatAppendedNothingAreNotCounted() {
        var attribution = TransactionWriteAttribution()
        attribution.note(site: "A.swift:1", frames: 0)
        attribution.note(site: "A.swift:1", frames: -3)
        XCTAssertEqual(attribution.totalCommits, 0)
        XCTAssertNil(attribution.takeLogLine(now: 1000.0))
    }

    func testTheLargestSiteComesFirstWithItsCommitsAndPeak() {
        var attribution = TransactionWriteAttribution()
        attribution.note(site: "A.swift:1", frames: 3)
        attribution.note(site: "B.swift:2", frames: 10)
        attribution.note(site: "A.swift:1", frames: 4)
        let line = attribution.takeLogLine(now: 1000.0) ?? ""
        XCTAssertTrue(line.contains("17 frames in 3 commits"), line)
        let bRange = line.range(of: "B.swift:2")
        let aRange = line.range(of: "A.swift:1")
        XCTAssertNotNil(bRange)
        XCTAssertNotNil(aRange)
        if let bRange, let aRange {
            XCTAssertTrue(bRange.lowerBound < aRange.lowerBound)
        }
        XCTAssertTrue(line.contains("A.swift:1 7 frames in 2 commits (max 4)"), line)
    }

    func testTheNextLineComesTenMinutesLaterAndCountsRestart() {
        var attribution = TransactionWriteAttribution()
        attribution.note(site: "A.swift:1", frames: 2)
        XCTAssertNotNil(attribution.takeLogLine(now: 1000.0))
        attribution.note(site: "A.swift:1", frames: 5)
        XCTAssertNil(attribution.takeLogLine(now: 1300.0))
        let line = attribution.takeLogLine(now: 1600.0) ?? ""
        XCTAssertTrue(line.contains("5 frames in 1 commits"), line)
        XCTAssertNil(attribution.takeLogLine(now: 5000.0), "nothing since the last line")
    }

    func testOnlyTheLargestSitesAreListedAndTheRestIsSummed() {
        var attribution = TransactionWriteAttribution()
        for index in 0 ..< 8 {
            attribution.note(site: "S\(index).swift:1", frames: 10 + index)
        }
        let line = attribution.takeLogLine(now: 1.0) ?? ""
        XCTAssertTrue(line.contains("others 21 frames"), line)
        XCTAssertFalse(line.contains("S0.swift"), line)
    }

    func testAClockGoingBackwardsDoesNotSilenceTheLog() {
        var attribution = TransactionWriteAttribution()
        attribution.note(site: "A.swift:1", frames: 1)
        XCTAssertNotNil(attribution.takeLogLine(now: 9000.0))
        attribution.note(site: "A.swift:1", frames: 1)
        XCTAssertNotNil(attribution.takeLogLine(now: 10.0))
    }

    func testALargeCommitIsLoggedAtOnceWithItsSite() {
        let line = TransactionWriteAttribution.largeCommitLine(site: "A.swift:7", frames: 5000, frameBytes: 4120)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("A.swift:7") == true, line ?? "")
        XCTAssertTrue(line?.contains("5000 frames") == true, line ?? "")
        XCTAssertNil(TransactionWriteAttribution.largeCommitLine(site: "A.swift:7", frames: 100, frameBytes: 4120))
        XCTAssertNil(TransactionWriteAttribution.largeCommitLine(site: "A.swift:7", frames: 0, frameBytes: 4120))
        XCTAssertNotNil(TransactionWriteAttribution.largeCommitLine(site: "B.swift:1", frames: 3, frameBytes: 4120, thresholdBytes: 10000))
    }
}
