import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import ReactionSelectionNode
import ContextUI

// Nanogram: a reaction chosen in the context menu while the keyboard is up. The menu is then in the keyboard
// window, where its flight and effect never show, so the chat plays the effect itself, the way a double tap does.
extension ChatControllerImpl {
    func contextMenuReactionItem(reaction: MessageReaction.Reaction, customFile: TelegramMediaFile?, availableReactions: AvailableReactions?) -> ReactionItem? {
        switch reaction {
        case .builtin, .stars:
            guard let availableReactions else {
                return nil
            }
            for available in availableReactions.reactions {
                guard let centerAnimation = available.centerAnimation else {
                    continue
                }
                guard let aroundAnimation = available.aroundAnimation else {
                    continue
                }
                if available.value == reaction {
                    return ReactionItem(
                        reaction: ReactionItem.Reaction(rawValue: available.value),
                        appearAnimation: available.appearAnimation,
                        stillAnimation: available.selectAnimation,
                        listAnimation: centerAnimation,
                        largeListAnimation: available.activateAnimation,
                        applicationAnimation: aroundAnimation,
                        largeApplicationAnimation: available.effectAnimation,
                        isCustom: false
                    )
                }
            }
            return nil
        case .custom:
            // The file comes from the chosen reaction: the message may not carry it yet for a first reaction.
            guard let customFile else {
                return nil
            }
            let file = TelegramMediaFile.Accessor(customFile)
            return ReactionItem(
                reaction: ReactionItem.Reaction(rawValue: reaction),
                appearAnimation: file,
                stillAnimation: file,
                listAnimation: file,
                largeListAnimation: file,
                applicationAnimation: nil,
                largeApplicationAnimation: nil,
                isCustom: true
            )
        }
    }

    /// Picks how a reaction chosen in `contextController` lands, and logs the decision (no message or peer data).
    func contextMenuReactionRoute(contextController: ContextController, targetView: UIView?, reactionItem: ReactionItem?) -> ContextReactionLandingRoute {
        let menuWindow = contextController.view.window
        let chatWindow = self.chatDisplayNode.view.window
        let route = contextReactionLandingRoute(
            hasTargetView: targetView != nil,
            menuWindow: menuWindow.map { ObjectIdentifier($0) },
            chatWindow: chatWindow.map { ObjectIdentifier($0) },
            hasStandaloneItem: reactionItem != nil
        )
        let menuWindowName = menuWindow.map { String(describing: type(of: $0)) } ?? "none"
        let sameWindow = menuWindow != nil && menuWindow === chatWindow
        let targetInMenu = targetView != nil && targetView?.window === menuWindow
        let inputHeight = Int(self.validLayout?.inputHeight ?? 0.0)
        Logger.shared.shortLog("ReactionKB", "applied target=\(targetView != nil ? "found" : "missing") route=\(route) menuWin=\(menuWindowName) sameWin=\(sameWindow ? "Y" : "N") targetInMenu=\(targetInMenu ? "Y" : "N") inputHeight=\(inputHeight)")
        return route
    }

    /// Call after the menu's `dismiss()`: the dismissal moves the extracted bubble back into the chat's tree
    /// (portal staging), so the effect is measured against the bubble's place in the chat.
    func playContextReactionInChat(messageId: EngineMessage.Id, reactionItem: ReactionItem, targetView: UIView) {
        guard let animationCache = self.controllerInteraction?.presentationContext.animationCache else {
            return
        }
        Logger.shared.shortLog("ReactionKB", "standalone targetInChatWin=\(targetView.window != nil && targetView.window === self.chatDisplayNode.view.window ? "Y" : "N")")
        let standaloneReactionAnimation = StandaloneReactionAnimation(genericReactionEffect: self.chatDisplayNode.historyNode.takeGenericReactionEffect())
        
        self.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: messageId, standaloneReactionAnimation: standaloneReactionAnimation)
        
        self.chatDisplayNode.addSubnode(standaloneReactionAnimation)
        standaloneReactionAnimation.frame = self.chatDisplayNode.bounds
        standaloneReactionAnimation.animateReactionSelection(
            context: self.context,
            theme: self.presentationData.theme,
            animationCache: animationCache,
            reaction: reactionItem,
            avatarPeers: [],
            playHaptic: false,
            isLarge: false,
            targetView: targetView,
            addStandaloneReactionAnimation: { [weak self] standaloneReactionAnimation in
                guard let self else {
                    return
                }
                self.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: messageId, standaloneReactionAnimation: standaloneReactionAnimation)
                standaloneReactionAnimation.frame = self.chatDisplayNode.bounds
                self.chatDisplayNode.addSubnode(standaloneReactionAnimation)
            },
            completion: { [weak standaloneReactionAnimation] in
                standaloneReactionAnimation?.removeFromSupernode()
            }
        )
    }
}
