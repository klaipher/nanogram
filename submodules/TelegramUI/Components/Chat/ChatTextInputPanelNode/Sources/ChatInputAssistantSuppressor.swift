import Foundation
import UIKit
import Display

// Nanogram: the input assistant (shortcuts) bar under the chat's sticker/emoji/GIF panel on iPad.
//
// In sticker mode the chat keeps its text view focused with an empty custom input view
// (`ChatControllerNode.chatPresentationInterfaceStateInputView`). iPadOS then shows the text view's input
// assistant bar (undo/redo/paste, about 80pt) at the bottom of the screen and reports it as a keyboard. Nothing
// is drawn there by the app, so upstream lifted the panel's switch above an empty band, and every other screen
// (the tab bar, the chat list's toolbar) moved up for it too. Emptying the assistant item's groups while the
// sticker panel is open makes iPadOS show no bar and report no keyboard, as the attachment caption field
// (`AttachmentTextInputPanelNode`) already does. The groups come back when the text keyboard does.

/// Whether the assistant bar is hidden: on iPad while the sticker/emoji/GIF panel replaces the keyboard. iPhone
/// (iPhone Duo included) shows no such bar and stays upstream.
public func chatSuppressesInputAssistant(isMediaInput: Bool, deviceType: DeviceType?) -> Bool {
    return isMediaInput && deviceType == .tablet
}

/// The responder in `root`'s view tree whose input view is `inputView`: the view that becomes first responder.
/// The composer has several editor backends, and in some the focused view sits inside the editor's view.
public func chatInputResponder(in root: UIView, withInputView inputView: UIView) -> UIResponder? {
    if root.inputView === inputView {
        return root
    }
    for subview in root.subviews {
        if let result = chatInputResponder(in: subview, withInputView: inputView) {
            return result
        }
    }
    return nil
}

/// Empties a responder's input assistant groups and puts them back later.
public final class ChatInputAssistantSuppressor {
    private weak var responder: UIResponder?
    private var savedLeadingGroups: [UIBarButtonItemGroup] = []
    private var savedTrailingGroups: [UIBarButtonItemGroup] = []

    public init() {
    }

    /// With `suppress` and a responder, empties that responder's groups (restoring any other responder first).
    /// Otherwise restores the responder it emptied, if any.
    public func update(responder: UIResponder?, suppress: Bool) {
        guard suppress, let responder else {
            self.restore()
            return
        }
        if self.responder === responder {
            return
        }
        self.restore()
        let item = responder.inputAssistantItem
        self.savedLeadingGroups = item.leadingBarButtonGroups
        self.savedTrailingGroups = item.trailingBarButtonGroups
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        self.responder = responder
    }

    private func restore() {
        if let responder = self.responder {
            let item = responder.inputAssistantItem
            item.leadingBarButtonGroups = self.savedLeadingGroups
            item.trailingBarButtonGroups = self.savedTrailingGroups
        }
        self.responder = nil
        self.savedLeadingGroups = []
        self.savedTrailingGroups = []
    }
}
