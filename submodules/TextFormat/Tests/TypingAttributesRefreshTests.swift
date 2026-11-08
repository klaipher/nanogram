import XCTest
import UIKit
@testable import TextFormat

/// The composer refreshes the typing attributes on every keystroke (twice: after the text change and after the
/// selection change). On iOS 27 the system keyboard runs in our process; a programmatic trait write inside a held delete
/// is a candidate for cancelling the key repeat, so an unchanged set is not written again.
final class TypingAttributesRefreshTests: XCTestCase {
    private final class CountingTextView: UITextView {
        var typingAttributesWrites = 0

        override var typingAttributes: [NSAttributedString.Key: Any] {
            get {
                return super.typingAttributes
            }
            set {
                self.typingAttributesWrites += 1
                super.typingAttributes = newValue
            }
        }
    }

    func testAnUnchangedSetIsNotWrittenAgain() {
        let textView = CountingTextView(frame: CGRect(x: 0.0, y: 0.0, width: 200.0, height: 40.0))
        textView.attributedText = NSAttributedString(string: "hello", attributes: [.font: UIFont.systemFont(ofSize: 17.0), .foregroundColor: UIColor.black])
        refreshChatTextInputTypingAttributes(textView, textColor: .black, baseFontSize: 17.0)
        let afterFirst = textView.typingAttributesWrites
        XCTAssertGreaterThanOrEqual(afterFirst, 1)
        refreshChatTextInputTypingAttributes(textView, textColor: .black, baseFontSize: 17.0)
        refreshChatTextInputTypingAttributes(textView, textColor: .black, baseFontSize: 17.0)
        XCTAssertEqual(textView.typingAttributesWrites, afterFirst, "the same attributes are not written again")
    }

    func testAChangedSetIsWritten() {
        let textView = CountingTextView(frame: CGRect(x: 0.0, y: 0.0, width: 200.0, height: 40.0))
        refreshChatTextInputTypingAttributes(textView, textColor: .black, baseFontSize: 17.0)
        let afterFirst = textView.typingAttributesWrites
        refreshChatTextInputTypingAttributes(textView, textColor: .red, baseFontSize: 17.0)
        XCTAssertEqual(textView.typingAttributesWrites, afterFirst + 1)
        XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? UIColor, .red)
    }
}
