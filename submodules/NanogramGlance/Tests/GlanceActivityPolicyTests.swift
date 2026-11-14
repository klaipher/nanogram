import XCTest
@testable import NanogramGlance

final class GlanceActivityPolicyTests: XCTestCase {
    func testHeadlineHidesTheNameUnlessAllowed() {
        XCTAssertEqual(GlanceActivityPolicy.headline(base: "Live Location", name: "Anna", showsNames: true), "Live Location · Anna")
        XCTAssertEqual(GlanceActivityPolicy.headline(base: "Live Location", name: "Anna", showsNames: false), "Live Location")
        XCTAssertEqual(GlanceActivityPolicy.headline(base: "Live Location", name: nil, showsNames: true), "Live Location")
    }

    func testStaleDateIsTheSharingEndCappedAndNeverPast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day = 24.0 * 3600.0
        XCTAssertEqual(GlanceActivityPolicy.staleDate(expiresAt: now.addingTimeInterval(3600), now: now, fallback: day), now.addingTimeInterval(3600))
        XCTAssertEqual(GlanceActivityPolicy.staleDate(expiresAt: now.addingTimeInterval(10 * day), now: now, fallback: day), now.addingTimeInterval(day))
        XCTAssertEqual(GlanceActivityPolicy.staleDate(expiresAt: nil, now: now, fallback: 8 * 3600), now.addingTimeInterval(8 * 3600))
        XCTAssertEqual(GlanceActivityPolicy.staleDate(expiresAt: now.addingTimeInterval(-5), now: now, fallback: day), now.addingTimeInterval(60))
    }
}
