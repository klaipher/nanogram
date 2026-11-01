import XCTest
@testable import tgwatch_Watch_App

/// The tests run inside the app (TEST_HOST), so `Bundle.main` is the built watch app.
final class BundleIdentityTests: XCTestCase {
    func testDisplayNameIsNanogram() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Nanogram")
    }

    /// The Bazel rule sets only PRODUCT_BUNDLE_IDENTIFIER ("<host>.watchkitapp"); the companion
    /// id must follow it, or the host app rejects the embedded watch app.
    func testCompanionIdIsDerivedFromBundleId() throws {
        let bundleId = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertTrue(bundleId.hasSuffix(".watchkitapp"), bundleId)
        let companion = Bundle.main.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String
        XCTAssertEqual(companion, String(bundleId.dropLast(".watchkitapp".count)))
    }
}
