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

final class GlanceActivityRequestTests: XCTestCase {
    private func request(stale: Date, startedAt: Date = Date(timeIntervalSince1970: 100), live: Bool = true) -> GlanceActivityRequest {
        return GlanceActivityRequest(kind: .call, accountId: 1, peerId: 2, stopLabel: "End", headline: "Call", status: "Connecting", startedAt: startedAt, endsAt: nil, staleDate: stale, isTimerLive: live, chatKeys: ["1:2"])
    }

    func testStaleDateIsNotPartOfTheContent() {
        XCTAssertEqual(self.request(stale: Date(timeIntervalSince1970: 1000)), self.request(stale: Date(timeIntervalSince1970: 2000)))
    }

    func testStartTimeCountsOnlyOnceTheTimerIsLive() {
        let later = Date(timeIntervalSince1970: 500)
        XCTAssertNotEqual(self.request(stale: Date(), live: true), self.request(stale: Date(), startedAt: later, live: true))
        XCTAssertEqual(self.request(stale: Date(), live: false), self.request(stale: Date(), startedAt: later, live: false))
    }

    func testChangedContentIsADifferentRequest() {
        var other = self.request(stale: Date())
        other.status = "In progress"
        XCTAssertNotEqual(self.request(stale: Date()), other)
    }
}
