import Foundation
import UIKit
import Display
import TabBarUI
import ChatPresentationInterfaceState
import ChatTextInputPanelNode

// Nanogram: Esc in a chat (hardware keyboard). The chat's own key commands replaced the base controller's, which
// carried Esc (back), so Esc did nothing in a chat. The order is `chatEscapeAction` (ChatTabletInputRules.swift).
extension ChatControllerImpl {
    /// Esc, or nothing (`chatHandlesEscapeKey`): iPhone keeps upstream, and a text field focused outside the chat
    /// (the chat list's search field in split view) keeps its controller's Esc. The window asks for key commands
    /// on every key press, so the focus is the current one.
    var escapeKeyShortcuts: [KeyShortcut] {
        let deviceType = self.validLayout?.deviceMetrics.type
        guard chatHandlesEscapeKey(deviceType: deviceType, firstResponderIsOutsideChat: deviceType == .tablet && self.isFirstResponderOutsideChat()) else {
            return []
        }
        return [KeyShortcut(input: UIKeyCommand.inputEscape, action: { [weak self] in
            self?.performEscapeKeyAction()
        })]
    }

    private func isFirstResponderOutsideChat() -> Bool {
        guard self.isViewLoaded, let firstResponder = currentFirstResponderView() else {
            return false
        }
        return !firstResponder.isDescendant(of: self.view)
    }

    private func performEscapeKeyAction() {
        let state = self.presentationInterfaceState
        var isMediaInputOpen = false
        if case .media = state.inputMode {
            isMediaInputOpen = true
        }
        let escapeState = ChatEscapeState(
            isEditing: state.interfaceState.editMessage != nil,
            hasReply: state.interfaceState.replyMessageSubject != nil,
            hasForward: state.interfaceState.forwardMessageIds != nil,
            isMediaInputOpen: isMediaInputOpen,
            isSearchActive: state.search != nil,
            isSelecting: state.interfaceState.selectionState != nil,
            canNavigateBack: !(self.navigationController?.topViewController is TabBarController)
        )
        guard let action = chatEscapeAction(escapeState) else {
            return
        }
        switch action {
        case .cancelEditing:
            self.interfaceInteraction?.setupEditMessage(nil, { _ in })
        case .cancelReply:
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) } })
        case .cancelForward:
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withUpdatedForwardMessageIds(nil).withUpdatedForwardOptionsState(nil) } })
        case .closeMediaInput:
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInputMode { _ in ChatInputMode.none } })
        case .closeSearch:
            self.interfaceInteraction?.dismissMessageSearch()
        case .cancelSelection:
            self.cancelSelectingMessages()
        case .navigateBack:
            let _ = self.navigationBar?.executeBack()
        }
    }
}

// The first responder, found by sending an action to it (no tree walk on every key press). A first responder that
// is not a view (the window's key-command responder) counts as none.
private final class FirstResponderCapture {
    static weak var responder: UIResponder?
}

private extension UIResponder {
    @objc func nanogram_captureFirstResponder(_ sender: Any?) {
        FirstResponderCapture.responder = self
    }
}

private func currentFirstResponderView() -> UIView? {
    FirstResponderCapture.responder = nil
    UIApplication.shared.sendAction(#selector(UIResponder.nanogram_captureFirstResponder(_:)), to: nil, from: nil, for: nil)
    let responder = FirstResponderCapture.responder
    FirstResponderCapture.responder = nil
    return responder as? UIView
}
