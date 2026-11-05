import Foundation
import XCTest
@testable import DCTMultiAnimationRendererImpl

final class DCTAnimationTickPolicyTests: XCTestCase {
    func testFullRateWhenNothingIsConstrained() {
        XCTAssertEqual(DCTAnimationTickPolicy.frameSkip(isLowPowerMode: false, thermalState: .nominal, processorCount: 6), 1)
        XCTAssertEqual(DCTAnimationTickPolicy.frameSkip(isLowPowerMode: false, thermalState: .fair, processorCount: 6), 1)
    }

    func testLowPowerModeHalvesTheRate() {
        XCTAssertEqual(DCTAnimationTickPolicy.frameSkip(isLowPowerMode: true, thermalState: .nominal, processorCount: 6), 2)
    }

    func testSeriousAndCriticalThermalStateHalveTheRate() {
        XCTAssertEqual(DCTAnimationTickPolicy.frameSkip(isLowPowerMode: false, thermalState: .serious, processorCount: 6), 2)
        XCTAssertEqual(DCTAnimationTickPolicy.frameSkip(isLowPowerMode: false, thermalState: .critical, processorCount: 6), 2)
    }

    func testTwoCoreDevicesKeepTheirExistingHalfRate() {
        XCTAssertEqual(DCTAnimationTickPolicy.frameSkip(isLowPowerMode: false, thermalState: .nominal, processorCount: 2), 2)
        XCTAssertEqual(DCTAnimationTickPolicy.frameSkip(isLowPowerMode: false, thermalState: .nominal, processorCount: 1), 2)
        XCTAssertEqual(DCTAnimationTickPolicy.frameSkip(isLowPowerMode: false, thermalState: .nominal, processorCount: 0), 2)
    }

    func testFramesPerSecondOfATickInterval() {
        XCTAssertEqual(DCTAnimationTickPolicy.framesPerSecond(forTickInterval: 1.0 / 60.0), 60)
        XCTAssertEqual(DCTAnimationTickPolicy.framesPerSecond(forTickInterval: 2.0 / 60.0), 30)
    }

    func testFramesPerSecondOfOddIntervalsDoesNotTrap() {
        XCTAssertEqual(DCTAnimationTickPolicy.framesPerSecond(forTickInterval: 0.0), 60)
        XCTAssertEqual(DCTAnimationTickPolicy.framesPerSecond(forTickInterval: -1.0), 60)
        XCTAssertEqual(DCTAnimationTickPolicy.framesPerSecond(forTickInterval: Double.nan), 60)
        XCTAssertEqual(DCTAnimationTickPolicy.framesPerSecond(forTickInterval: Double.infinity), 1)
        XCTAssertEqual(DCTAnimationTickPolicy.framesPerSecond(forTickInterval: Double.leastNonzeroMagnitude), 60)
    }

    func testElapsedIsTheTimeBetweenTargetTimestamps() {
        // A 60 Hz link driving a 40 Hz tick: callbacks come 25 ms apart (1.5 frames, the link fires on the frame after).
        XCTAssertEqual(DCTAnimationTickPolicy.elapsed(target: 10.025, previousTarget: 10.0, interval: 1.0 / 40.0), 0.025, accuracy: 1e-9)
        XCTAssertEqual(DCTAnimationTickPolicy.elapsed(target: 10.05, previousTarget: 10.0, interval: 1.0 / 30.0), 0.05, accuracy: 1e-9)
    }

    func testFirstCallbackAdvancesOneInterval() {
        XCTAssertEqual(DCTAnimationTickPolicy.elapsed(target: 10.0, previousTarget: nil, interval: 1.0 / 30.0), 1.0 / 30.0, accuracy: 1e-9)
    }

    func testElapsedIsClampedToFourIntervalsAfterAGap() {
        XCTAssertEqual(DCTAnimationTickPolicy.elapsed(target: 12.0, previousTarget: 10.0, interval: 1.0 / 30.0), 4.0 / 30.0, accuracy: 1e-9)
    }

    func testElapsedNeverFallsBelowTheInterval() {
        // Two callbacks in one frame, or a clock that did not move.
        XCTAssertEqual(DCTAnimationTickPolicy.elapsed(target: 10.0, previousTarget: 10.0, interval: 1.0 / 30.0), 1.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(DCTAnimationTickPolicy.elapsed(target: 9.0, previousTarget: 10.0, interval: 1.0 / 30.0), 1.0 / 30.0, accuracy: 1e-9)
    }

    func testNonFiniteTimestampsFallBackToTheInterval() {
        XCTAssertEqual(DCTAnimationTickPolicy.elapsed(target: Double.nan, previousTarget: 10.0, interval: 0.05), 0.05, accuracy: 1e-9)
        XCTAssertEqual(DCTAnimationTickPolicy.elapsed(target: Double.infinity, previousTarget: 10.0, interval: 0.05), 0.05, accuracy: 1e-9)
    }
}
