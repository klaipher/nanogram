import Foundation
import XCTest
import NanogramFeatures

final class LinkHygieneTests: XCTestCase {
    func testUtmAndClickIdsAreRemoved() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/a?utm_source=x&id=5&fbclid=abc&utm_medium=y"), "https://example.com/a?id=5")
    }

    func testNothingLeftDropsTheQuestionMark() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/a?utm_source=x&gclid=1"), "https://example.com/a")
    }

    func testFragmentAndOrderAreKept() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/a?b=1&igshid=z&a=2#top"), "https://example.com/a?b=1&a=2#top")
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/a?igshid=z#x?y=1"), "https://example.com/a#x?y=1")
    }

    func testLinksWithoutTrackingAreReturnedAsGiven() {
        let link = "https://example.com/a?q=a%20b&x"
        XCTAssertEqual(LinkHygiene.strippingTracking(link), link)
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/plain"), "https://example.com/plain")
    }

    func testNamesAreCaseInsensitive() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/?UTM_Source=x&k=1"), "https://example.com/?k=1")
    }

    func testHostScopedEntries() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://www.youtube.com/watch?v=abc&si=xyz"), "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(LinkHygiene.strippingTracking("https://example.com/?si=xyz"), "https://example.com/?si=xyz")
        XCTAssertEqual(LinkHygiene.strippingTracking("https://notyoutube.com/?si=xyz"), "https://notyoutube.com/?si=xyz")
    }

    func testAQuestionMarkInsideTheFragmentIsNotAQuery() {
        let link = "https://example.com/p#frag?utm_source=x"
        XCTAssertEqual(LinkHygiene.strippingTracking(link), link)
    }

    func testOtherSchemesAreUntouched() {
        XCTAssertEqual(LinkHygiene.strippingTracking("tg://resolve?domain=a&utm_source=x"), "tg://resolve?domain=a&utm_source=x")
        XCTAssertEqual(LinkHygiene.strippingTracking("not a link?utm_source=x"), "not a link?utm_source=x")
    }

    func testPortAndUserInfoDoNotBreakTheHostMatch() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://user@www.youtube.com:443/watch?v=1&si=2"), "https://user@www.youtube.com:443/watch?v=1")
    }

    func testTelegramLinks() {
        XCTAssertTrue(LinkHygiene.isTelegramLink("https://t.me/durov"))
        XCTAssertTrue(LinkHygiene.isTelegramLink("HTTP://T.ME?x=1"))
        XCTAssertTrue(LinkHygiene.isTelegramLink("tg://resolve?domain=a"))
        XCTAssertTrue(LinkHygiene.isTelegramLink("https://telegram.me/a"))
        XCTAssertFalse(LinkHygiene.isTelegramLink("https://t.me.evil.com/a"))
        XCTAssertFalse(LinkHygiene.isTelegramLink("https://example.com/t.me"))
        // Shared behaviour of the iOS and Mac apps: www.t.me counts, telesco.pe and a bare "tg:" do not.
        XCTAssertTrue(LinkHygiene.isTelegramLink("https://www.t.me/durov"))
        XCTAssertFalse(LinkHygiene.isTelegramLink("https://telesco.pe/durov"))
        XCTAssertFalse(LinkHygiene.isTelegramLink("tg:resolve?domain=a"))
    }

    func testEmptyQueryItemsAreKeptWhenSomethingElseIsRemoved() {
        XCTAssertEqual(LinkHygiene.strippingTracking("https://a.com/p?x=1&&utm_source=z&y=2"), "https://a.com/p?x=1&&y=2")
    }

    func testStandardListMatchesTheSharedDataFile() throws {
        // The one list is data/link-tracking-params.txt of nanogram-deps: shared/data in the iOS repository, and
        // submodules/telegram-ios/shared/data when the Mac compiles this test through its symlink.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = ["shared/data/link-tracking-params.txt", "submodules/telegram-ios/shared/data/link-tracking-params.txt"]
        guard let contents = candidates.lazy.compactMap({ try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }).first else {
            throw XCTSkip("shared/data/link-tracking-params.txt is not reachable from the test sandbox")
        }
        let file = TrackingParameterList(fileContents: contents)
        XCTAssertEqual(file.ruleCount, TrackingParameterList.standard.ruleCount)
        for sample in [("utm_x", "a.com"), ("si", "youtu.be"), ("si", "a.com"), ("pd_rd_w", "www.amazon.com"), ("__cft__[0]", "facebook.com"), ("id", "a.com")] {
            XCTAssertEqual(file.isTracking(name: sample.0, host: sample.1), TrackingParameterList.standard.isTracking(name: sample.0, host: sample.1))
        }
    }
}
