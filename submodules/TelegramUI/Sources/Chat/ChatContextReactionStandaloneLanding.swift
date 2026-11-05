import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import ReactionSelectionNode

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

    func playContextReactionInChat(messageId: EngineMessage.Id, reactionItem: ReactionItem, targetView: UIView) {
        guard let animationCache = self.controllerInteraction?.presentationContext.animationCache else {
            return
        }
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
