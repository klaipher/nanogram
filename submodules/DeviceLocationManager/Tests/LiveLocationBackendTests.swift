import XCTest
import CoreLocation
@testable import DeviceLocationManager

/// Stationary-aware live updates (iOS 17) serve live location alone; a screen that needs the compass, or any device
/// below iOS 17, keeps the CLLocationManager path. The flag is off by default.
final class LiveLocationBackendTests: XCTestCase {
    private func configuration(_ modes: [DeviceLocationMode]) throws -> DeviceLocationConfiguration {
        return try XCTUnwrap(deviceLocationConfiguration(modes: modes))
    }

    func testLiveLocationAloneUsesLiveUpdatesWhenEnabled() throws {
        XCTAssertEqual(deviceLocationBackend(configuration: try configuration([.preciseAlways]), stationaryUpdatesEnabled: true, isLiveUpdatesAvailable: true), .liveUpdates)
    }

    func testFlagOffKeepsTheLocationManager() throws {
        XCTAssertEqual(deviceLocationBackend(configuration: try configuration([.preciseAlways]), stationaryUpdatesEnabled: false, isLiveUpdatesAvailable: true), .locationManager)
    }

    func testOldSystemsKeepTheLocationManager() throws {
        XCTAssertEqual(deviceLocationBackend(configuration: try configuration([.preciseAlways]), stationaryUpdatesEnabled: true, isLiveUpdatesAvailable: false), .locationManager)
    }

    func testAScreenNeedingTheCompassKeepsTheLocationManager() throws {
        XCTAssertEqual(deviceLocationBackend(configuration: try configuration([.preciseForeground]), stationaryUpdatesEnabled: true, isLiveUpdatesAvailable: true), .locationManager)
        XCTAssertEqual(deviceLocationBackend(configuration: try configuration([.preciseAlways, .preciseForeground]), stationaryUpdatesEnabled: true, isLiveUpdatesAvailable: true), .locationManager)
    }

    func testSmallMovesAreSkippedLikeTheDistanceFilter() {
        let origin = CLLocation(latitude: 50.0, longitude: 30.0)
        let near = CLLocation(latitude: 50.00003, longitude: 30.0)
        let far = CLLocation(latitude: 50.0002, longitude: 30.0)
        XCTAssertTrue(shouldDeliverLiveUpdate(previous: nil, next: origin, distanceFilter: 10.0))
        XCTAssertFalse(shouldDeliverLiveUpdate(previous: origin, next: origin, distanceFilter: 10.0))
        XCTAssertFalse(shouldDeliverLiveUpdate(previous: origin, next: near, distanceFilter: 10.0))
        XCTAssertTrue(shouldDeliverLiveUpdate(previous: origin, next: far, distanceFilter: 10.0))
        XCTAssertTrue(shouldDeliverLiveUpdate(previous: origin, next: origin, distanceFilter: kCLDistanceFilterNone))
    }

    func testTheFlagIsOffByDefault() {
        let suiteName = "DeviceLocationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("no defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(defaults.bool(forKey: deviceLocationStationaryUpdatesDefaultsKey))
    }
}
