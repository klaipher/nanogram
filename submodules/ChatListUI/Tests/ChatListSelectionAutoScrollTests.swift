import XCTest
import UIKit
@testable import ChatListUI

/// Drag-to-select in the chat list scrolls the list while the finger rests near its top or bottom
/// edge. That scroll ran on a 60 fps link and moved a fixed step per tick, so it was capped at 60 Hz.
/// It now ticks at the display rate with the step scaled by the tick's duration.
final class ChatListSelectionAutoScrollTests: XCTestCase {
    private func run(rate: Double, seconds: Double, delta: CGFloat) -> (distance: CGFloat, selectionUpdates: Int, ticks: Int) {
        var scroll = ChatListSelectionAutoScroll()
        var distance: CGFloat = 0.0
        var updates = 0
        var ticks = 0
        var time = 100.0
        let end = time + seconds
        while time < end - 1e-9 {
            let step = scroll.tick(delta: delta, now: time)
            distance += step.distance
            if step.updatesSelection {
                updates += 1
            }
            ticks += 1
            time += 1.0 / rate
        }
        return (distance, updates, ticks)
    }

    func test_scrollSpeedIsTheSameAt60And120Hz() {
        for delta: CGFloat in [0.1, 0.5, -0.8, 1.0] {
            let at60 = run(rate: 60.0, seconds: 1.0, delta: delta)
            let at120 = run(rate: 120.0, seconds: 1.0, delta: delta)
            XCTAssertEqual(at120.ticks, 2 * at60.ticks)
            XCTAssertEqual(at120.distance, at60.distance, accuracy: at60.distance * 0.02, "delta \(delta)")
        }
    }

    func test_at60HzEachTickIsTheOriginalStep() {
        // The original closure scrolled 15 * min(1, 0.15 + delta^2) per 60 fps tick.
        var scroll = ChatListSelectionAutoScroll()
        for tick in 0 ..< 10 {
            let step = scroll.tick(delta: 0.6, now: 50.0 + Double(tick) / 60.0)
            XCTAssertEqual(step.distance, 15.0 * min(1.0, 0.15 + 0.36), accuracy: 1e-9)
        }
    }

    func test_selectionIsRefreshedThirtyTimesASecondAtAnyRate() {
        // The original refreshed the selection on every other 60 fps tick.
        let at60 = run(rate: 60.0, seconds: 1.0, delta: 1.0)
        let at120 = run(rate: 120.0, seconds: 1.0, delta: 1.0)
        XCTAssertEqual(at60.selectionUpdates, 30)
        XCTAssertEqual(at120.selectionUpdates, 30)
    }

    func test_firstTickAfterAPauseMovesOneFrameStep() {
        var scroll = ChatListSelectionAutoScroll()
        let _ = scroll.tick(delta: 1.0, now: 10.0)
        scroll.pause()
        let resumed = scroll.tick(delta: 1.0, now: 12.0)
        XCTAssertEqual(resumed.distance, 15.0, accuracy: 1e-9)
    }

    func test_aStalledTickMovesAtMostTwoFrameSteps() {
        var scroll = ChatListSelectionAutoScroll()
        let _ = scroll.tick(delta: 1.0, now: 10.0)
        let stalled = scroll.tick(delta: 1.0, now: 10.5)
        XCTAssertEqual(stalled.distance, 30.0, accuracy: 1e-9)
    }
}
