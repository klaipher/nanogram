import XCTest
@testable import Display

final class KeyboardAutocorrectionTests: XCTestCase {
    private func needs(_ text: String, caret: Int? = nil, length: Int = 0, marked: Bool = false) -> Bool {
        let location = caret ?? (text as NSString).length
        return needsAutocorrectionCommit(text: text, selection: NSRange(location: location, length: length), hasMarkedText: marked)
    }

    func testMarkedTextAlwaysNeedsACommit() {
        XCTAssertTrue(self.needs("", marked: true))
        XCTAssertTrue(self.needs("hello ", marked: true))
    }

    func testACaretAfterAWordNeedsACommit() {
        XCTAssertTrue(self.needs("helo"))
        XCTAssertTrue(self.needs("see you tomorow"))
        XCTAssertTrue(self.needs("привіт"))
        XCTAssertTrue(self.needs("ok!"), "punctuation glued to a word")
    }

    func testACaretAfterWhitespaceOrAtTheStartHasNothingPending() {
        XCTAssertFalse(self.needs("hello "))
        XCTAssertFalse(self.needs("hello\n"))
        XCTAssertFalse(self.needs("hello", caret: 0))
        XCTAssertFalse(self.needs(""))
    }

    func testALastWordWithoutLettersHasNothingToCorrect() {
        XCTAssertFalse(self.needs("call 12345"))
        XCTAssertFalse(self.needs("..."))
        XCTAssertFalse(self.needs("hi 👍"))
    }

    func testARangeSelectionHasNothingPending() {
        XCTAssertFalse(self.needs("hello world", caret: 5, length: 3))
    }

    func testAnOutOfRangeSelectionIsHandled() {
        XCTAssertFalse(self.needs("hi", caret: 10))
        XCTAssertFalse(needsAutocorrectionCommit(text: "hi", selection: NSRange(location: NSNotFound, length: 0), hasMarkedText: false))
    }
}
