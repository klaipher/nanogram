import Foundation
import XCTest

final class DustEffectPolicyTests: XCTestCase {
    func testFrameDeltaTimeUsesTargetTimestamps() {
        XCTAssertEqual(DustEffectTiming.frameDeltaTime(targetTimestamp: 10.0 + 2.0 / 120.0, previousTargetTimestamp: 10.0, frameDuration: 1.0 / 120.0), 2.0 / 120.0, accuracy: 1e-9)
    }

    func testFrameDeltaTimeFallsBackOnFirstFrameAndStalls() {
        XCTAssertEqual(DustEffectTiming.frameDeltaTime(targetTimestamp: 10.0, previousTargetTimestamp: nil, frameDuration: 1.0 / 60.0), 1.0 / 60.0)
        XCTAssertEqual(DustEffectTiming.frameDeltaTime(targetTimestamp: nil, previousTargetTimestamp: nil, frameDuration: 1.0 / 60.0), 1.0 / 60.0)
        // A stall, a repeated target and a clock going back all take the frame duration.
        XCTAssertEqual(DustEffectTiming.frameDeltaTime(targetTimestamp: 11.0, previousTargetTimestamp: 10.0, frameDuration: 1.0 / 120.0), 1.0 / 120.0)
        XCTAssertEqual(DustEffectTiming.frameDeltaTime(targetTimestamp: 10.0, previousTargetTimestamp: 10.0, frameDuration: 1.0 / 120.0), 1.0 / 120.0)
        XCTAssertEqual(DustEffectTiming.frameDeltaTime(targetTimestamp: 9.0, previousTargetTimestamp: 10.0, frameDuration: 1.0 / 120.0), 1.0 / 120.0)
    }

    func testItemFinishesOnlyAfterLongestLifetimeAtFullSpeed() {
        var progress = DustEffectItemProgress()
        // Time during the sweep does not count: grains still start moving then.
        for _ in 0 ..< 1000 {
            progress.didDispatchUpdate(phase: 0.5, simulationTimeStep: 1.0 / 60.0)
        }
        XCTAssertFalse(progress.isFinished)

        // 4.1 s of simulation time is not enough with the margin; 4.2 is.
        for _ in 0 ..< 246 {
            progress.didDispatchUpdate(phase: 0.8, simulationTimeStep: 1.0 / 60.0)
        }
        XCTAssertFalse(progress.isFinished)
        for _ in 0 ..< 6 {
            progress.didDispatchUpdate(phase: 1.5, simulationTimeStep: 1.0 / 60.0)
        }
        XCTAssertTrue(progress.isFinished)
    }

    func testMaxDurationIsPastTheNaturalEnd() {
        // The natural end is the sweep plus 4.1 s of simulation time at twice the animation speed.
        XCTAssertGreaterThan(DustEffectTiming.maxDuration(animationSpeed: 1.0), 0.8 + 2.05 + 1.0)
        XCTAssertGreaterThan(DustEffectTiming.maxDuration(animationSpeed: 2.2), 0.8 / 2.2 + 2.05 + 1.0)
        XCTAssertTrue(DustEffectTiming.maxDuration(animationSpeed: 0.0).isFinite)
    }

    func testQuality() {
        XCTAssertEqual(DustEffectQuality.current(isLowPowerModeEnabled: false, thermalState: .nominal), .full)
        XCTAssertEqual(DustEffectQuality.current(isLowPowerModeEnabled: false, thermalState: .fair), .full)

        let lowPower = DustEffectQuality.current(isLowPowerModeEnabled: true, thermalState: .nominal)
        XCTAssertFalse(lowPower.usesHighFrameRateDuringSweep)
        XCTAssertEqual(lowPower.particleStride, 2)
        XCTAssertTrue(lowPower.isFluidEnabled)

        XCTAssertEqual(DustEffectQuality.current(isLowPowerModeEnabled: false, thermalState: .serious), lowPower)

        let critical = DustEffectQuality.current(isLowPowerModeEnabled: false, thermalState: .critical)
        XCTAssertFalse(critical.usesHighFrameRateDuringSweep)
        XCTAssertFalse(critical.isFluidEnabled)
    }

    func testParticleGrid() {
        let full = DustEffectQuality.full.particleGrid(itemSize: CGSize(width: 280.6, height: 64.0))
        XCTAssertEqual(full.columns, 280)
        XCTAssertEqual(full.rows, 64)

        let halved = DustEffectQuality.current(isLowPowerModeEnabled: true, thermalState: .nominal).particleGrid(itemSize: CGSize(width: 281.0, height: 64.0))
        XCTAssertEqual(halved.columns, 140)
        XCTAssertEqual(halved.rows, 32)

        let empty = DustEffectQuality.full.particleGrid(itemSize: CGSize(width: 0.5, height: 64.0))
        XCTAssertEqual(empty.columns, 0)

        let invalid = DustEffectQuality.full.particleGrid(itemSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity))
        XCTAssertEqual(invalid.columns, 0)
        XCTAssertEqual(invalid.rows, 0)
    }
}
