import Foundation
import UIKit
import Display
import TabBarUI
import ChatPresentationInterfaceState
import ChatTextInputPanelNode

// Nanogram: Esc in a chat (hardware keyboard). The chat's own key commands replaced the base controller's, which
// carried Esc (back), so Esc did nothing in a chat. The order is `chatEscapeAction` (ChatTabletInputRules.swift).
extension ChatControllerImpl {
    var escapeKeyShortcut: KeyShortcut {
        return KeyShortcut(input: UIKeyCommand.inputEscape, action: { [weak self] in
            self?.performEscapeKeyAction()
        })
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
