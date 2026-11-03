import XCTest
import CoreLocation
@testable import DeviceLocationManager

/// Live location runs for hours in the background. Only a screen the user is looking at (a map, the location picker)
/// needs every fix and the compass; live location alone sends one update per 4 s and takes its heading from the
/// course while moving. And only live location needs Always access.
final class DeviceLocationConfigurationTests: XCTestCase {
    func testAScreenOnLocationGetsEveryFixAndTheCompass() {
        let configuration = deviceLocationConfiguration(modes: [.preciseForeground])
        XCTAssertEqual(configuration?.distanceFilter, kCLDistanceFilterNone)
        XCTAssertEqual(configuration?.updatesHeading, true)
        XCTAssertEqual(configuration?.allowsBackgroundUpdates, false)
        XCTAssertEqual(configuration?.authorization, .whenInUse)
    }

    func testLiveLocationAloneSkipsSmallMovesAndTheCompass() {
        let configuration = deviceLocationConfiguration(modes: [.preciseAlways])
        XCTAssertEqual(configuration?.distanceFilter, 10.0)
        XCTAssertEqual(configuration?.updatesHeading, false)
        XCTAssertEqual(configuration?.allowsBackgroundUpdates, true)
        XCTAssertEqual(configuration?.authorization, .always)
    }

    func testLiveLocationWithAMapOpenIsPrecise() {
        let configuration = deviceLocationConfiguration(modes: [.preciseAlways, .preciseForeground])
        XCTAssertEqual(configuration?.distanceFilter, kCLDistanceFilterNone)
        XCTAssertEqual(configuration?.updatesHeading, true)
        XCTAssertEqual(configuration?.allowsBackgroundUpdates, true)
        XCTAssertEqual(configuration?.authorization, .always)
    }

    func testNothingRunsWithoutSubscribers() {
        XCTAssertNil(deviceLocationConfiguration(modes: []))
    }
}
