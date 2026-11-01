import XCTest
import UIKit
@testable import Display

/// `ListViewImpl.transferVelocity` coasts the list after a pan that started outside it (a profile
/// header handing its flick to a pane). It ran on a 60 fps link and moved a fixed amount per tick, so
/// at 120 Hz it would have travelled twice as far. The step is now scaled by the tick's duration.
final class ListViewTransferVelocityTests: XCTestCase {
    /// Total travel of one coast, ticking at `rate` Hz until the step's velocity drops below the stop
    /// threshold, the way the display link drives it.
    private func coastDistance(velocity: CGFloat, rate: Double) -> (distance: CGFloat, duration: Double) {
        let frame = 1.0 / rate
        var previous = 0.0
        var distance: CGFloat = 0.0
        var time = frame
        while time < 10.0 {
            let step = listViewTransferVelocityStep(velocity: velocity, elapsed: time, sincePreviousTick: time - previous)
            distance += step.offset
            previous = time
            if step.isFinished {
                break
            }
            time += frame
        }
        return (distance, time)
    }

    func test_coastTravelsTheSameDistanceAt60And120Hz() {
        for velocity: CGFloat in [-3.0, -0.5, 0.4, 1.0, 2.5] {
            let at60 = coastDistance(velocity: velocity, rate: 60.0)
            let at120 = coastDistance(velocity: velocity, rate: 120.0)
            XCTAssertEqual(at120.distance, at60.distance, accuracy: abs(at60.distance) * 0.03, "velocity \(velocity)")
            XCTAssertEqual(at120.duration, at60.duration, accuracy: 1.0 / 60.0 + 1e-9, "velocity \(velocity)")
        }
    }

    func test_at60HzTheStepIsTheOriginalPerFrameStep() {
        // The original closure added `velocity * 15 * 0.998^(1000 t)` per 60 fps tick.
        let velocity: CGFloat = 1.7
        for tick in 1 ... 30 {
            let t = Double(tick) / 60.0
            let step = listViewTransferVelocityStep(velocity: velocity, elapsed: t, sincePreviousTick: 1.0 / 60.0)
            let original = velocity * 15.0 * CGFloat(pow(0.998, 1000.0 * t))
            XCTAssertEqual(step.offset, original, accuracy: 1e-9)
        }
    }

    func test_aLongTickIsCappedSoAStallDoesNotJump() {
        let normal = listViewTransferVelocityStep(velocity: 1.0, elapsed: 0.1, sincePreviousTick: 1.0 / 60.0)
        let stalled = listViewTransferVelocityStep(velocity: 1.0, elapsed: 0.1, sincePreviousTick: 0.5)
        XCTAssertLessThanOrEqual(stalled.offset, normal.offset * 2.0 + 1e-9)
    }
}
