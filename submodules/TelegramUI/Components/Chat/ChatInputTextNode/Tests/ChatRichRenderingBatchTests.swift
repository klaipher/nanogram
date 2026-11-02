import XCTest
import UIKit
import TextFormat
@testable import ChatInputTextNode

/// The spoiler/custom-emoji overlays were rebuilt 3 times inside every `textViewDidChange` (two inset updates and
/// the host's decoration), each a full attribute scan plus `selectionRects` per emoji and spoiler. Only the state at
/// the end of the change is visible, so they are now rebuilt once, when the change has been handled.
final class ChatRichRenderingBatchTests: XCTestCase {
    private final class HostDelegate: NSObject, ChatInputTextNodeDelegate {
        weak var node: ChatRichTextInputNodeImpl?

        func chatInputTextNodeDidUpdateText() {
            // What the chat panel does: decorate, which renders the overlays.
            self.node?.updateRichRendering(textColor: .black, fullTranslucency: true)
        }
        func chatInputTextNodeShouldReturn(modifierFlags: UIKeyModifierFlags) -> Bool { return true }
        func chatInputTextNodeDidChangeSelection(dueToEditing: Bool) {}
        func chatInputTextNodeDidBeginEditing() {}
        func chatInputTextNodeDidFinishEditing() {}
        func chatInputTextNodeBackspaceWhileEmpty() {}
        func chatInputTextNodeMenu(forTextRange textRange: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu { return UIMenu(children: []) }
        func chatInputTextNode(shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool { return true }
        func chatInputTextNodeShouldCopy() -> Bool { return true }
        func chatInputTextNodeShouldPaste() -> Bool { return true }
        func chatInputTextNodeShouldRespondToAction(action: Selector) -> Bool { return true }
        func chatInputTextNodeTargetForAction(action: Selector) -> ChatInputTextNode.TargetForAction? { return nil }
    }

    func testOneRenderingPerTextChange() {
        let node = ChatRichTextInputNodeImpl()
        let delegate = HostDelegate()
        delegate.node = node
        node.inputDelegate = delegate
        node.frame = CGRect(x: 0.0, y: 0.0, width: 300.0, height: 100.0)
        let textView = node.textInputNodeImpl.textView
        let text = NSMutableAttributedString(string: "hello secret world", attributes: [.font: UIFont.systemFont(ofSize: 17.0), .foregroundColor: UIColor.black])
        text.addAttribute(ChatTextInputAttributes.spoiler, value: true as NSNumber, range: NSRange(location: 6, length: 6))
        textView.attributedText = text
        node.updateRichRendering(textColor: .black, fullTranslucency: true)

        // The keystroke itself (UIKit's insert); its layout pass renders once on its own, as before.
        textView.textStorage.replaceCharacters(in: NSRange(location: textView.textStorage.length, length: 0), with: "!")
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let before = node.richRenderingPassesForTesting
        textView.textViewDidChange(textView)
        XCTAssertEqual(node.richRenderingPassesForTesting - before, 1)
        XCTAssertFalse(textView.isHandlingTextChange)

        // Outside a text change it renders right away, as before.
        node.updateRichRendering(textColor: .black, fullTranslucency: true)
        XCTAssertEqual(node.richRenderingPassesForTesting - before, 2)
    }
}
