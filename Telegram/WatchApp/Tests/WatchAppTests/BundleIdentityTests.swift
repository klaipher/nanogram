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

/// IOS-WATCH-ATS-1: the watch app makes no HTTP requests (network goes through TDLib's own sockets), so it
/// must not carry a blanket App Transport Security exemption.
final class AppTransportSecurityTests: XCTestCase {
    func testInfoPlistHasNoAppTransportSecurityExemption() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity"))
    }

    /// A future URLSession, AsyncImage or WKWebView would load plain HTTP silently under the old exemption.
    /// If one is added on purpose, give it a narrow NSExceptionDomains entry instead and update this guard.
    func testSourcesDoNotUseTheNetworkStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tgwatch Watch App")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["URLSession", "AsyncImage", "WKWebView"] {
                XCTAssertFalse(text.contains(needle), "\(url.lastPathComponent) uses \(needle)")
            }
        }
    }
}
