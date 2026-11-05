import XCTest
import TelegramCore
@testable import TextFormat

/// Text such as "@7 (pm)" must survive convertMarkdownToAttributes (upstream Mac #205).
final class MentionParenthesisMarkdownTests: XCTestCase {
    func testMentionLikeTextIsKept() {
        let result = convertMarkdownToAttributes(NSAttributedString(string: "see @7 (pm) ok"))
        XCTAssertEqual(result.string, "see @7 (pm) ok")
    }

    func testMentionLikeTextAloneIsKept() {
        let result = convertMarkdownToAttributes(NSAttributedString(string: "@7 (pm)"))
        XCTAssertEqual(result.string, "@7 (pm)")
    }

    func testBoldStillConvertedNextToMentionLikeText() {
        let result = convertMarkdownToAttributes(NSAttributedString(string: "@7 (pm) **x**"))
        XCTAssertEqual(result.string, "@7 (pm) x")
        var range = NSRange()
        let attrs = result.attributes(at: result.length - 1, effectiveRange: &range)
        XCTAssertNotNil(attrs[ChatTextInputAttributes.bold])
    }
}
