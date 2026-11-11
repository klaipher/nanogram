import XCTest
@testable import CoreListDemo

final class PhysicsScrollEngineRefreshRateTests: XCTestCase {
    func testTheSamplingLinkIsNotPinnedByDefault() {
        XCTAssertFalse(PhysicsScrollEngine.pinsSamplingLinkRate, "the sampler only drives row loading; pinning it doubles the main-thread work")
        XCTAssertTrue(PhysicsScrollEngine.pinsMaximumRefreshRate, "the animation keeps its rate guarantee")
    }

    func testAProMotionPanelPinsItsMaximumRate() {
        XCTAssertEqual(PhysicsScrollEngine.pinnedFrameRate(pinsMaximumRefreshRate: true, maximumFramesPerSecond: 120, isLowPowerMode: false), 120.0)
    }

    func testLowPowerModeDoesNotPin() {
        XCTAssertNil(PhysicsScrollEngine.pinnedFrameRate(pinsMaximumRefreshRate: true, maximumFramesPerSecond: 120, isLowPowerMode: true))
    }

    func testSixtyHertzPanelsAndDisabledPinningDoNotPin() {
        XCTAssertNil(PhysicsScrollEngine.pinnedFrameRate(pinsMaximumRefreshRate: true, maximumFramesPerSecond: 60, isLowPowerMode: false))
        XCTAssertNil(PhysicsScrollEngine.pinnedFrameRate(pinsMaximumRefreshRate: false, maximumFramesPerSecond: 120, isLowPowerMode: false))
    }
}
