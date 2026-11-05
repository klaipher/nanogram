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
}
