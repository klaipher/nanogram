import Foundation
import XCTest
@testable import Postbox

final class MediaBoxFileManagerStatsTests: XCTestCase {
    func testNothingIsLoggedBeforeAnyFileIsOpened() {
        var stats = MediaBoxFileManagerStats()
        XCTAssertNil(stats.takeLogLine(now: 100.0, currentlyOpen: 0))
    }

    func testReopensAreCountedApartFromOpens() {
        var stats = MediaBoxFileManagerStats()
        stats.noteOpen(isReopen: false)
        stats.noteOpen(isReopen: false)
        stats.noteOpen(isReopen: true)
        XCTAssertEqual(stats.opened, 3)
        XCTAssertEqual(stats.reopened, 1)
    }

    func testTheFirstLineComesAtOnceAndTheNextOneAMinuteLater() {
        var stats = MediaBoxFileManagerStats()
        stats.noteOpen(isReopen: false)
        let first = stats.takeLogLine(now: 1000.0, currentlyOpen: 1)
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.contains("opened=1 reopened=0") == true, first ?? "")

        stats.noteOpen(isReopen: true)
        XCTAssertNil(stats.takeLogLine(now: 1030.0, currentlyOpen: 1), "less than a minute after the last line")
        let second = stats.takeLogLine(now: 1060.0, currentlyOpen: 1)
        XCTAssertTrue(second?.contains("opened=1 reopened=1") == true, second ?? "")
        XCTAssertTrue(second?.contains("total opened=2 reopened=1") == true, second ?? "")
        XCTAssertNil(stats.takeLogLine(now: 1200.0, currentlyOpen: 1), "nothing opened since the last line")
    }

    func testAClockGoingBackwardsDoesNotSilenceTheLog() {
        var stats = MediaBoxFileManagerStats()
        stats.noteOpen(isReopen: false)
        XCTAssertNotNil(stats.takeLogLine(now: 5000.0, currentlyOpen: 1))
        stats.noteOpen(isReopen: false)
        XCTAssertNotNil(stats.takeLogLine(now: 100.0, currentlyOpen: 1))
    }
}
