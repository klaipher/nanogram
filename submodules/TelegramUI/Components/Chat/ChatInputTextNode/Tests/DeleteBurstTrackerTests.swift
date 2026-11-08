import XCTest
@testable import ChatInputTextNode

/// One log line per run of deletes: how many the keyboard delivered and how many programmatic text or caret writes the
/// composer made meanwhile. A held key that logs `count=1` got no repeats from the keyboard; `writes>0` points at us.
final class DeleteBurstTrackerTests: XCTestCase {
    func testAHeldKeyIsOneBurstWithItsRepeats() {
        var tracker = DeleteBurstTracker()
        XCTAssertNil(tracker.recordDelete(at: 10.0))
        XCTAssertNil(tracker.recordDelete(at: 10.5))
        XCTAssertNil(tracker.recordDelete(at: 10.6))
        tracker.recordProgrammaticWrite(at: 10.62)
        let summary = tracker.finish(at: 11.5)
        XCTAssertEqual(summary, "Composer delete burst: count=3 spanMs=600 writes=1")
    }

    func testAPauseStartsANewBurstAndReturnsTheOldOne() {
        var tracker = DeleteBurstTracker()
        XCTAssertNil(tracker.recordDelete(at: 10.0))
        let previous = tracker.recordDelete(at: 11.0)
        XCTAssertEqual(previous, "Composer delete burst: count=1 spanMs=0 writes=0")
        XCTAssertEqual(tracker.finish(at: 12.0), "Composer delete burst: count=1 spanMs=0 writes=0")
    }

    func testWritesOutsideABurstAreNotCounted() {
        var tracker = DeleteBurstTracker()
        tracker.recordProgrammaticWrite(at: 5.0)
        XCTAssertNil(tracker.recordDelete(at: 10.0))
        tracker.recordProgrammaticWrite(at: 10.0 + DeleteBurstTracker.gap + 0.1)
        XCTAssertEqual(tracker.finish(at: 12.0), "Composer delete burst: count=1 spanMs=0 writes=0")
        XCTAssertNil(tracker.finish(at: 13.0), "nothing is pending after a finish")
        XCTAssertFalse(tracker.hasOpenRun, "so the app stops asking")
    }

    func testFinishBeforeTheGapKeepsTheBurstOpen() {
        var tracker = DeleteBurstTracker()
        XCTAssertNil(tracker.recordDelete(at: 10.0))
        XCTAssertNil(tracker.finish(at: 10.2))
        XCTAssertNil(tracker.recordDelete(at: 10.3))
        XCTAssertEqual(tracker.finish(at: 11.0), "Composer delete burst: count=2 spanMs=300 writes=0")
    }
}
