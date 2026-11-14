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

    func testAMapOpeningAndClosingSwitchesTheBackendBothWays() throws {
        let live = try configuration([.preciseAlways])
        let withMap = try configuration([.preciseAlways, .preciseForeground])
        let backends = [live, withMap, live].map {
            deviceLocationBackend(configuration: $0, stationaryUpdatesEnabled: true, isLiveUpdatesAvailable: true)
        }
        XCTAssertEqual(backends, [.liveUpdates, .locationManager, .liveUpdates])
    }

    func testARepeatedStationaryFixPublishesNothing() {
        let origin = CLLocation(latitude: 50.0, longitude: 30.0)
        let far = CLLocation(latitude: 50.0002, longitude: 30.0)
        var last: CLLocation?
        var published: [CLLocation] = []
        for fix in [origin, origin, origin, far, far] {
            if shouldDeliverLiveUpdate(previous: last, next: fix, distanceFilter: 10.0) {
                last = fix
                published.append(fix)
            }
        }
        XCTAssertEqual(published, [origin, far])
    }

    func testInjectedFixesReachTheCallbackInOrder() {
        let fixes = (0 ..< 3).map { CLLocation(latitude: 50.0 + Double($0) * 0.001, longitude: 30.0) }
        let received = LockedFixes()
        let done = expectation(description: "all fixes delivered")
        let updates = LiveLocationUpdates(source: {
            return AsyncStream { continuation in
                for fix in fixes {
                    continuation.yield(fix)
                }
                continuation.finish()
            }
        }, startsSessions: false, onUpdate: { location in
            if received.append(location) == 3 {
                done.fulfill()
            }
        })
        wait(for: [done], timeout: 5.0)
        XCTAssertEqual(received.values, fixes)
        updates.stop()
    }

    func testStoppingOrReleasingCancelsTheSource() {
        let stoppedByStop = expectation(description: "stop cancels the source")
        let stoppedByRelease = expectation(description: "release cancels the source")
        func make(_ expectation: XCTestExpectation) -> LiveLocationUpdates {
            return LiveLocationUpdates(source: {
                return AsyncStream { continuation in
                    continuation.onTermination = { _ in
                        expectation.fulfill()
                    }
                }
            }, startsSessions: false, onUpdate: { _ in })
        }
        let first = make(stoppedByStop)
        first.stop()
        var second: LiveLocationUpdates? = make(stoppedByRelease)
        second = nil
        XCTAssertNil(second)
        wait(for: [stoppedByStop, stoppedByRelease], timeout: 5.0)
    }
}

private final class LockedFixes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CLLocation] = []

    var values: [CLLocation] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ location: CLLocation) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append(location)
        return self.storage.count
    }
}
