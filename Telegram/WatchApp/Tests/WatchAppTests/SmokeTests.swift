import XCTest
@testable import tgwatch_Watch_App

final class SmokeTests: XCTestCase {
    func testAppModuleLoads() {
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
    }
}
