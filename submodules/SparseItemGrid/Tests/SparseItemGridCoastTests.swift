import XCTest
import UIKit
@testable import SparseItemGrid

/// The profile's Media, Files, Music and Voice tabs coast their grid after a flick that started on the
/// profile header (`SparseItemGrid.transferVelocity`). The coast ran on a 60 fps link and moved a fixed
/// amount per tick, so on a 120 Hz screen the list moved on every other frame while the rest of the
/// screen moved on every frame. It now ticks at the display rate with the step scaled to the tick.
final class SparseItemGridCoastTests: XCTestCase {
    /// Runs one coast at `rate` Hz the way the display link drives it.
    private func coast(velocity: CGFloat, rate: Double, startOffset: CGFloat = 0.0, maxOffset: CGFloat = 100_000.0) -> (offset: CGFloat, ticks: Int, duration: Double) {
        let frame = 1.0 / rate
        var previous = 0.0
        var offset = startOffset
        var time = frame
        var ticks = 0
        while time < 10.0 {
            let tick = sparseItemGridCoastTick(offset: offset, maxOffset: maxOffset, velocity: velocity, elapsed: time, sincePreviousTick: time - previous)
            offset = tick.offset
            previous = time
            ticks += 1
            if tick.isFinished {
                break
            }
            time += frame
        }
        return (offset, ticks, time)
    }

    func test_coastTravelsTheSameDistanceAt60And120Hz() {
        for velocity: CGFloat in [0.4, 1.0, 2.5, 6.0] {
            let at60 = self.coast(velocity: velocity, rate: 60.0)
            let at120 = self.coast(velocity: velocity, rate: 120.0)
            XCTAssertEqual(at120.offset, at60.offset, accuracy: at60.offset * 0.03, "velocity \(velocity)")
            XCTAssertEqual(at120.duration, at60.duration, accuracy: 1.0 / 60.0 + 1e-9, "velocity \(velocity)")
            // Smoothness: at 120 Hz the list must get a new position on every frame, not every other one.
            XCTAssertGreaterThanOrEqual(at120.ticks, at60.ticks * 2 - 2, "velocity \(velocity)")
            print("BENCH grid coast v=\(velocity): 60 Hz \(at60.ticks) steps over \(Int(at60.offset)) pt, 120 Hz \(at120.ticks) steps over \(Int(at120.offset)) pt")
        }
    }

    func test_at60HzTheCoastMatchesTheOriginalPerFrameSteps() {
        // The original closure added `velocity * 15 * 0.998^(1000 t)` to the offset on every 60 fps tick.
        let velocity: CGFloat = 1.7
        var offset: CGFloat = 0.0
        var original: CGFloat = 0.0
        for frame in 1 ... 30 {
            let t = Double(frame) / 60.0
            offset = sparseItemGridCoastTick(offset: offset, maxOffset: 100_000.0, velocity: velocity, elapsed: t, sincePreviousTick: 1.0 / 60.0).offset
            original += velocity * 15.0 * CGFloat(pow(0.998, 1000.0 * t))
        }
        XCTAssertEqual(offset, original, accuracy: 1e-6)
    }

    func test_theCoastStopsAtTheEndOfTheContent() {
        let tick = sparseItemGridCoastTick(offset: 995.0, maxOffset: 1000.0, velocity: 3.0, elapsed: 1.0 / 60.0, sincePreviousTick: 1.0 / 60.0)
        XCTAssertEqual(tick.offset, 1000.0)
        XCTAssertTrue(tick.isFinished)
    }

    func test_aStalledFrameDoesNotJump() {
        let normal = sparseItemGridCoastTick(offset: 0.0, maxOffset: 100_000.0, velocity: 1.0, elapsed: 0.1, sincePreviousTick: 1.0 / 60.0)
        let stalled = sparseItemGridCoastTick(offset: 0.0, maxOffset: 100_000.0, velocity: 1.0, elapsed: 0.1, sincePreviousTick: 0.5)
        XCTAssertLessThanOrEqual(stalled.offset, normal.offset * 2.0 + 1e-9)
    }
}
