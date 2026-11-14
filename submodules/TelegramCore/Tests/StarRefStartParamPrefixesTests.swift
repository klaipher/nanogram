import XCTest
@testable import TelegramCore

final class StarRefStartParamPrefixesTests: XCTestCase {
    func testArrayFromTheServer() {
        let config: JSON = .dictionary(["starref_start_param_prefixes": .array([.string("_a_"), .string("_b_")])])
        XCTAssertEqual(StarRefStartParamPrefixes.prefixes(appConfiguration: config), ["_a_", "_b_"])
    }

    func testStringIsAccepted() {
        let config: JSON = .dictionary(["starref_start_param_prefixes": .string("_x_")])
        XCTAssertEqual(StarRefStartParamPrefixes.prefixes(appConfiguration: config), ["_x_"])
    }

    func testMissingOrEmptyFallsBackToDefault() {
        XCTAssertEqual(StarRefStartParamPrefixes.prefixes(appConfiguration: nil), ["_tgr_"])
        XCTAssertEqual(StarRefStartParamPrefixes.prefixes(appConfiguration: .dictionary([:])), ["_tgr_"])
        XCTAssertEqual(StarRefStartParamPrefixes.prefixes(appConfiguration: .dictionary(["starref_start_param_prefixes": .array([])])), ["_tgr_"])
        XCTAssertEqual(StarRefStartParamPrefixes.prefixes(appConfiguration: .dictionary(["starref_start_param_prefixes": .array([.string("")])])), ["_tgr_"])
    }

    func testReferrerStripsTheMatchingPrefix() {
        XCTAssertEqual(StarRefStartParamPrefixes.referrer(startParam: "_b_42", prefixes: ["_a_", "_b_"]), "42")
        XCTAssertNil(StarRefStartParamPrefixes.referrer(startParam: "plain", prefixes: ["_a_"]))
    }
}
