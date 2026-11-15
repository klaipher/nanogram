import XCTest
import UIKit
import TelegramCore
import ChatInputTextNode
@testable import ComposerHarnessLib

/// Shared arrange steps for the engine-backend regression tests added in the second roam.
/// The older test files each carry their own `root()`; this one is shared because the three
/// families below need the same three extra handles (the node, the engine text view, a settle).
enum HarnessEngine {
    /// The host app's root view controller. The scene delegate installs it when the window scene
    /// connects, which can land after the first test starts, so poll the run loop for it.
    /// Set once the first wait ran out: later tests fail at once instead of each waiting 30 s again (about 860 tests
    /// need the root, so a host whose scene never connects would otherwise outlast the target's timeout).
    private static var rootWaitExpired = false

    static func awaitHarnessRoot() throws -> HarnessRootViewController {
        if !HarnessEngine.rootWaitExpired {
            let deadline = Date().addingTimeInterval(30.0)
            while AppDelegate.harnessRootViewController == nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            if AppDelegate.harnessRootViewController == nil {
                HarnessEngine.rootWaitExpired = true
            }
        }
        return try XCTUnwrap(
            AppDelegate.harnessRootViewController,
            "harness step 1: AppDelegate.harnessRootViewController is nil after waiting 30 s once (no window scene connected to the test host, or the root was released)")
    }

    static func root() throws -> HarnessRootViewController {
        let value = try HarnessEngine.awaitHarnessRoot()
        value.loadViewIfNeeded()
        value.view.frame = CGRect(x: 0.0, y: 0.0, width: 402.0, height: 874.0)
        let deadline = Date().addingTimeInterval(30.0)
        while value.panelHost == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        value.view.layoutIfNeeded()
        return value
    }

    /// Lets the editor's coalesced selection/change deliveries and the root's layout pass land.
    static func settle(_ root: HarnessRootViewController, seconds: TimeInterval = 0.3) {
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        root.view.layoutIfNeeded()
    }

    static func node(_ host: HarnessPanelHost) throws -> ChatRichTextInputNode {
        XCTAssertEqual(host.liveBackend, .engine, "harness step 4: the engine backend is not live after setBackend(.engine)")
        return try XCTUnwrap(host.panel.richTextInputNode, "harness step 4: the panel has no rich input node")
    }

    /// The engine's `UITextInput` view. It is what UIKit (and the keyboard) actually talks to,
    /// so traits, selection geometry and the undo manager are read from it rather than from a wrapper.
    static func textView(in root: HarnessRootViewController) throws -> UIView {
        func find(_ view: UIView) -> UIView? {
            if NSStringFromClass(type(of: view)) == "TGIDObservingBlockTextView" {
                return view
            }
            for subview in view.subviews {
                if let found = find(subview) {
                    return found
                }
            }
            return nil
        }
        return try XCTUnwrap(find(root.view), "harness step 5: no TGIDObservingBlockTextView in the root view hierarchy")
    }

    static func paragraph(_ text: String, _ attributes: ChatInputInlineAttributes = ChatInputInlineAttributes()) -> ChatInputBlock {
        return .paragraph(ChatInputParagraph(style: .body, list: nil, runs: [ChatInputRun(text: text, attributes: attributes)]))
    }
}
