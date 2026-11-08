import XCTest
import UIKit
@testable import Display

/// Debug Settings "List scroll: log frame rate": one line per scroll gesture with the scroll's real frame rate.
final class ListViewScrollPacingTests: XCTestCase {
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        self.lines = []
        ListViewScrollPacing.isEnabled = true
        ListViewScrollPacing.log = { [weak self] line in
            self?.lines.append(line)
        }
    }

    override func tearDown() {
        ListViewScrollPacing.isEnabled = false
        ListViewScrollPacing.log = nil
        ListViewScrollPacing.context = nil
        super.tearDown()
    }

    func test_steady120HzScrollLogsItsRateAndNoLateFrames() {
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        var t = 10.0
        pacing.beginGesture(timestamp: t)
        for _ in 0 ... 120 {
            pacing.didScroll(timestamp: t, maximumFramesPerSecond: 120)
            t += 1.0 / 120.0
        }
        let line = pacing.endGesture(timestamp: t)
        XCTAssertEqual(self.lines.count, 1)
        XCTAssertEqual(line, self.lines.first)
        XCTAssertTrue(line?.contains("list=ChatListNode") == true, line ?? "")
        XCTAssertTrue(line?.contains("frames=120") == true, line ?? "")
        XCTAssertTrue(line?.contains("avgHz=120.0") == true, line ?? "")
        XCTAssertTrue(line?.contains("late=0") == true, line ?? "")
    }

    func test_60HzScrollOnA120HzScreenCountsEveryFrameLate() {
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        var t = 0.0
        pacing.beginGesture(timestamp: t)
        for _ in 0 ... 60 {
            pacing.didScroll(timestamp: t, maximumFramesPerSecond: 120)
            t += 1.0 / 60.0
        }
        let line = pacing.endGesture(timestamp: t)
        XCTAssertTrue(line?.contains("avgHz=60.0") == true, line ?? "")
        XCTAssertTrue(line?.contains("late=60") == true, line ?? "")
    }

    func test_aFingerRestIsNotALateFrame() {
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        pacing.beginGesture(timestamp: 0.0)
        pacing.didScroll(timestamp: 0.0, maximumFramesPerSecond: 120)
        pacing.didScroll(timestamp: 1.0 / 120.0, maximumFramesPerSecond: 120)
        // The finger rests for half a second, then the scroll goes on.
        pacing.didScroll(timestamp: 0.5, maximumFramesPerSecond: 120)
        pacing.didScroll(timestamp: 0.5 + 1.0 / 120.0, maximumFramesPerSecond: 120)
        let line = pacing.endGesture(timestamp: 0.6)
        XCTAssertTrue(line?.contains("frames=2") == true, line ?? "")
        XCTAssertTrue(line?.contains("late=0") == true, line ?? "")
    }

    func test_offLogsNothing() {
        ListViewScrollPacing.isEnabled = false
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        pacing.beginGesture(timestamp: 0.0)
        pacing.didScroll(timestamp: 0.0, maximumFramesPerSecond: 120)
        pacing.didScroll(timestamp: 1.0 / 120.0, maximumFramesPerSecond: 120)
        XCTAssertNil(pacing.endGesture(timestamp: 0.1))
        XCTAssertTrue(self.lines.isEmpty)
    }

    func test_aGestureWithoutMovementLogsNothing() {
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        pacing.beginGesture(timestamp: 0.0)
        XCTAssertNil(pacing.endGesture(timestamp: 0.2))
        XCTAssertTrue(self.lines.isEmpty)
    }

    private func scroll(_ pacing: ListViewScrollPacing, from t: inout Double, frames: Int, hz: Double) {
        for _ in 0 ..< frames {
            t += 1.0 / hz
            pacing.didScroll(timestamp: t, maximumFramesPerSecond: 120)
        }
    }

    /// ProMotion lowers the rate on purpose while a fling slows down; that is not a dropped frame.
    func test_theDecelerationSlowdownIsNeitherLateNorAJump() {
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        var t = 0.0
        pacing.beginGesture(timestamp: t)
        pacing.didScroll(timestamp: t, maximumFramesPerSecond: 120)
        self.scroll(pacing, from: &t, frames: 30, hz: 120.0)
        pacing.endDragging(timestamp: t, willDecelerate: true)
        self.scroll(pacing, from: &t, frames: 30, hz: 120.0)
        self.scroll(pacing, from: &t, frames: 20, hz: 80.0)
        self.scroll(pacing, from: &t, frames: 20, hz: 60.0)
        self.scroll(pacing, from: &t, frames: 10, hz: 40.0)
        self.scroll(pacing, from: &t, frames: 10, hz: 30.0)
        self.scroll(pacing, from: &t, frames: 5, hz: 20.0)
        let line = pacing.endGesture(timestamp: t) ?? ""
        XCTAssertTrue(line.contains("drag(frames=30 "), line)
        XCTAssertTrue(line.contains("late=0 "), line)
        XCTAssertTrue(line.contains("decel(frames=95 "), line)
        XCTAssertTrue(line.contains("jumps=0 "), line)
        XCTAssertTrue(line.contains("longestMs=50.0)"), line)
    }

    func test_aStallWhileDeceleratingIsAJump() {
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        var t = 0.0
        pacing.beginGesture(timestamp: t)
        pacing.didScroll(timestamp: t, maximumFramesPerSecond: 120)
        self.scroll(pacing, from: &t, frames: 10, hz: 120.0)
        pacing.endDragging(timestamp: t, willDecelerate: true)
        self.scroll(pacing, from: &t, frames: 10, hz: 120.0)
        self.scroll(pacing, from: &t, frames: 1, hz: 20.0)
        self.scroll(pacing, from: &t, frames: 10, hz: 120.0)
        let line = pacing.endGesture(timestamp: t) ?? ""
        XCTAssertTrue(line.contains("jumps=1 "), line)
    }

    func test_aStallWhileDraggingIsLate() {
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        var t = 0.0
        pacing.beginGesture(timestamp: t)
        pacing.didScroll(timestamp: t, maximumFramesPerSecond: 120)
        self.scroll(pacing, from: &t, frames: 10, hz: 120.0)
        self.scroll(pacing, from: &t, frames: 1, hz: 30.0)
        self.scroll(pacing, from: &t, frames: 10, hz: 120.0)
        pacing.endDragging(timestamp: t, willDecelerate: false)
        let line = pacing.endGesture(timestamp: t) ?? ""
        XCTAssertTrue(line.contains("drag(frames=21 "), line)
        XCTAssertTrue(line.contains("late=1 "), line)
        XCTAssertTrue(line.contains("decel(none)"), line)
    }

    /// The line says which A/B switches were on, so runs can be told apart from the log alone.
    func test_theSwitchStateIsAppended() {
        ListViewScrollPacing.context = { "rowReuse=on lazyRows=on" }
        let pacing = ListViewScrollPacing(listName: "ChatListNode")
        var t = 0.0
        pacing.beginGesture(timestamp: t)
        pacing.didScroll(timestamp: t, maximumFramesPerSecond: 120)
        self.scroll(pacing, from: &t, frames: 5, hz: 120.0)
        let line = pacing.endGesture(timestamp: t) ?? ""
        XCTAssertTrue(line.hasSuffix(" ab=rowReuse=on lazyRows=on"), line)
    }
}
