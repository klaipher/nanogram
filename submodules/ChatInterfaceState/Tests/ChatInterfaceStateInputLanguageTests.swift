import XCTest
@testable import ChatInterfaceState

final class ChatInterfaceStateInputLanguageTests: XCTestCase {
    func testUnchangedLanguageIsNoUpdate() {
        let state = ChatInterfaceState().withUpdatedInputLanguage("uk-UA")
        XCTAssertNil(state.withChangedInputLanguage({ _ in "uk-UA" }))
        XCTAssertNil(ChatInterfaceState().withChangedInputLanguage({ _ in nil }))
    }

    func testChangedLanguageIsApplied() {
        let state = ChatInterfaceState().withUpdatedInputLanguage("uk-UA")
        XCTAssertEqual(state.withChangedInputLanguage({ _ in "en-US" })?.inputLanguage, "en-US")
        XCTAssertEqual(state.withChangedInputLanguage({ _ in nil })?.inputLanguage, .some(nil))
        XCTAssertEqual(ChatInterfaceState().withChangedInputLanguage({ _ in "en-US" })?.inputLanguage, "en-US")
        XCTAssertEqual(state.withChangedInputLanguage({ $0.map { $0 + "x" } })?.inputLanguage, "uk-UAx")
    }

    // Everything else is kept.
    func testOtherFieldsAreKept() {
        let state = ChatInterfaceState().withUpdatedComposeDisableUrlPreviews(["https://telegram.org/"]).withUpdatedSilentPosting(true)
        let updated = state.withChangedInputLanguage({ _ in "de" })
        XCTAssertEqual(updated, state.withUpdatedInputLanguage("de"))
    }
}
