import Foundation
import XCTest
import NanogramFeatures

final class AppSchemeTests: XCTestCase {
    private func action(_ string: String) throws -> NanogramAppScheme.Action {
        return NanogramAppScheme.action(for: try XCTUnwrap(URL(string: string)))
    }

    private func url(_ string: String) throws -> URL {
        return try XCTUnwrap(URL(string: string))
    }

    func testBareSchemeOnlyOpensTheApp() throws {
        XCTAssertEqual(try action("nanogram://"), .openApp)
        XCTAssertEqual(try action("nanogram:"), .openApp)
        XCTAssertEqual(try action("nanogram:///"), .openApp)
        XCTAssertEqual(try action("NANOGRAM://"), .openApp)
    }

    func testPathBecomesATelegramLink() throws {
        XCTAssertEqual(try action("nanogram://resolve?domain=durov"), .open(try url("tg://resolve?domain=durov")))
        XCTAssertEqual(try action("Nanogram://settings"), .open(try url("tg://settings")))
    }

    func testOtherSchemesAreUnchanged() throws {
        XCTAssertEqual(try action("tg://resolve?domain=durov"), .open(try url("tg://resolve?domain=durov")))
        XCTAssertEqual(try action("https://t.me/durov"), .open(try url("https://t.me/durov")))
    }

    func testNoResultKeepsTheNanogramScheme() throws {
        for string in ["nanogram://", "nanogram://x", "nanogram:x"] {
            if case let .open(result) = try action(string) {
                XCTAssertNotEqual(result.scheme?.lowercased(), NanogramAppScheme.scheme, string)
            }
        }
    }
}
