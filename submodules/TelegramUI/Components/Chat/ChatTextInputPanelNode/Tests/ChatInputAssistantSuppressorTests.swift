import XCTest
import UIKit
import Display
import ChatTextInputPanelNode

final class ChatInputAssistantSuppressorTests: XCTestCase {
    // MARK: When

    /// iPad with the sticker panel open: the ~80pt assistant bar that left an empty band under the switch is hidden.
    func test_tablet_mediaInput_suppresses() {
        XCTAssertTrue(chatSuppressesInputAssistant(isMediaInput: true, deviceType: .tablet))
    }

    func test_tablet_textInput_doesNotSuppress() {
        XCTAssertFalse(chatSuppressesInputAssistant(isMediaInput: false, deviceType: .tablet))
    }

    /// iPhone and iPhone Duo (a regular-width phone) are upstream.
    func test_phone_neverSuppresses() {
        XCTAssertFalse(chatSuppressesInputAssistant(isMediaInput: true, deviceType: .phone))
        XCTAssertFalse(chatSuppressesInputAssistant(isMediaInput: true, deviceType: nil))
    }

    // MARK: Which responder

    func test_findsTheResponderInsideTheEditor() {
        let emptyInputView = UIView()
        let root = UIView()
        let container = UIView()
        let textView = UITextView()
        textView.inputView = emptyInputView
        root.addSubview(container)
        container.addSubview(UIView())
        container.addSubview(textView)
        XCTAssertTrue(chatInputResponder(in: root, withInputView: emptyInputView) === textView)
    }

    func test_findsTheRootItself() {
        let emptyInputView = UIView()
        let textView = UITextView()
        textView.inputView = emptyInputView
        XCTAssertTrue(chatInputResponder(in: textView, withInputView: emptyInputView) === textView)
    }

    func test_noResponder_isNil() {
        let root = UIView()
        root.addSubview(UITextView())
        XCTAssertNil(chatInputResponder(in: root, withInputView: UIView()))
    }

    // MARK: Emptying and restoring

    private func group(_ title: String) -> UIBarButtonItemGroup {
        return UIBarButtonItemGroup(barButtonItems: [UIBarButtonItem(title: title, style: .plain, target: nil, action: nil)], representativeItem: nil)
    }

    func test_suppressThenRestore() {
        let textView = UITextView()
        let leading = [self.group("undo")]
        let trailing = [self.group("paste")]
        textView.inputAssistantItem.leadingBarButtonGroups = leading
        textView.inputAssistantItem.trailingBarButtonGroups = trailing

        let suppressor = ChatInputAssistantSuppressor()
        suppressor.update(responder: textView, suppress: true)
        XCTAssertTrue(textView.inputAssistantItem.leadingBarButtonGroups.isEmpty)
        XCTAssertTrue(textView.inputAssistantItem.trailingBarButtonGroups.isEmpty)

        // Back to the text keyboard: the custom input view is gone, so there is no responder to pass.
        suppressor.update(responder: nil, suppress: false)
        XCTAssertEqual(textView.inputAssistantItem.leadingBarButtonGroups, leading)
        XCTAssertEqual(textView.inputAssistantItem.trailingBarButtonGroups, trailing)
    }

    /// A second update for the same responder must not save the emptied groups over the real ones.
    func test_suppressTwice_restoresTheOriginals() {
        let textView = UITextView()
        let leading = [self.group("undo")]
        textView.inputAssistantItem.leadingBarButtonGroups = leading

        let suppressor = ChatInputAssistantSuppressor()
        suppressor.update(responder: textView, suppress: true)
        suppressor.update(responder: textView, suppress: true)
        suppressor.update(responder: nil, suppress: false)
        XCTAssertEqual(textView.inputAssistantItem.leadingBarButtonGroups, leading)
    }

    /// Another editor takes over: the first one gets its groups back.
    func test_otherResponder_restoresThePreviousOne() {
        let first = UITextView()
        let second = UITextView()
        let leading = [self.group("undo")]
        first.inputAssistantItem.leadingBarButtonGroups = leading
        second.inputAssistantItem.leadingBarButtonGroups = [self.group("redo")]

        let suppressor = ChatInputAssistantSuppressor()
        suppressor.update(responder: first, suppress: true)
        suppressor.update(responder: second, suppress: true)
        XCTAssertEqual(first.inputAssistantItem.leadingBarButtonGroups, leading)
        XCTAssertTrue(second.inputAssistantItem.leadingBarButtonGroups.isEmpty)
    }

    /// Not suppressing (iPhone): nothing is touched.
    func test_notSuppressing_leavesTheGroups() {
        let textView = UITextView()
        let leading = [self.group("undo")]
        textView.inputAssistantItem.leadingBarButtonGroups = leading
        let suppressor = ChatInputAssistantSuppressor()
        suppressor.update(responder: textView, suppress: false)
        XCTAssertEqual(textView.inputAssistantItem.leadingBarButtonGroups, leading)
    }
}
