import Foundation
import XCTest
@testable import TelegramCallsUI

/// The thermal level of a call: the system thermal state and Low Power Mode mapped to four levels, raised at once
/// and lowered only after the cooler reading has held for five seconds, so the picture does not flap.
final class CallThermalGovernorTests: XCTestCase {
    func testMappingFollowsTheSystemThermalState() {
        XCTAssertEqual(CallThermalMapping.level(thermalState: .nominal, isLowPowerModeEnabled: false), .nominal)
        XCTAssertEqual(CallThermalMapping.level(thermalState: .fair, isLowPowerModeEnabled: false), .nominal)
        XCTAssertEqual(CallThermalMapping.level(thermalState: .serious, isLowPowerModeEnabled: false), .high)
        XCTAssertEqual(CallThermalMapping.level(thermalState: .critical, isLowPowerModeEnabled: false), .critical)
    }

    func testLowPowerModeRaisesACoolDeviceToElevatedButNeverLowersAHotOne() {
        XCTAssertEqual(CallThermalMapping.level(thermalState: .nominal, isLowPowerModeEnabled: true), .elevated)
        XCTAssertEqual(CallThermalMapping.level(thermalState: .fair, isLowPowerModeEnabled: true), .elevated)
        XCTAssertEqual(CallThermalMapping.level(thermalState: .serious, isLowPowerModeEnabled: true), .high)
        XCTAssertEqual(CallThermalMapping.level(thermalState: .critical, isLowPowerModeEnabled: true), .critical)
    }

    func testLevelsAreOrdered() {
        XCTAssertTrue(CallThermalLevel.nominal < .elevated)
        XCTAssertTrue(CallThermalLevel.elevated < .high)
        XCTAssertTrue(CallThermalLevel.high < .critical)
        XCTAssertEqual(CallThermalLevel.critical.rawValue, 3)
    }

    func testRisingIsImmediate() {
        var hysteresis = CallThermalHysteresis()
        XCTAssertEqual(hysteresis.update(raw: .nominal, now: 0.0), .nominal)
        XCTAssertEqual(hysteresis.update(raw: .high, now: 1.0), .high)
        XCTAssertEqual(hysteresis.update(raw: .critical, now: 1.1), .critical)
    }

    func testLoweringWaitsForTheCoolerReadingToHold() {
        var hysteresis = CallThermalHysteresis()
        _ = hysteresis.update(raw: .high, now: 0.0)
        XCTAssertEqual(hysteresis.update(raw: .nominal, now: 1.0), .high)
        XCTAssertEqual(hysteresis.update(raw: .nominal, now: 5.9), .high)
        XCTAssertEqual(hysteresis.update(raw: .nominal, now: 6.0), .nominal)
    }

    func testAReadingThatClimbsBackCancelsTheRelease() {
        var hysteresis = CallThermalHysteresis()
        _ = hysteresis.update(raw: .high, now: 0.0)
        XCTAssertEqual(hysteresis.update(raw: .nominal, now: 1.0), .high)
        XCTAssertEqual(hysteresis.update(raw: .high, now: 4.0), .high)
        // The five seconds start again from the next cooler reading.
        XCTAssertEqual(hysteresis.update(raw: .nominal, now: 5.0), .high)
        XCTAssertEqual(hysteresis.update(raw: .nominal, now: 9.9), .high)
        XCTAssertEqual(hysteresis.update(raw: .nominal, now: 10.0), .nominal)
    }

    func testReleaseLandsOnTheLatestReading() {
        var hysteresis = CallThermalHysteresis()
        _ = hysteresis.update(raw: .critical, now: 0.0)
        XCTAssertEqual(hysteresis.update(raw: .elevated, now: 1.0), .critical)
        XCTAssertEqual(hysteresis.update(raw: .high, now: 3.0), .critical)
        XCTAssertEqual(hysteresis.update(raw: .high, now: 6.0), .high)
    }

    func testReleaseTimeTellsWhenToLookAgain() {
        var hysteresis = CallThermalHysteresis()
        _ = hysteresis.update(raw: .high, now: 0.0)
        XCTAssertNil(hysteresis.releaseTime)
        _ = hysteresis.update(raw: .nominal, now: 2.0)
        XCTAssertEqual(hysteresis.releaseTime, 7.0)
    }

    func testTheVideoLadderOnlyActsFromHighUp() {
        XCTAssertFalse(CallThermalLevel.nominal.shrinksVideo)
        XCTAssertFalse(CallThermalLevel.elevated.shrinksVideo)
        XCTAssertTrue(CallThermalLevel.high.shrinksVideo)
        XCTAssertTrue(CallThermalLevel.critical.shrinksVideo)
    }
}
