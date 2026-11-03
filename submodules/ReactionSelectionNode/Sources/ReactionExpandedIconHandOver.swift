import Foundation
import AsyncDisplayKit
import Display

/// Keeps a picker item's drawn icon until the item's larger animation has drawn a frame.
///
/// A sent reaction's item switches to its larger animation (`listAnimation`, `largeListAnimation` for
/// the long-press reaction), flies into the message's button and stands in for the button's icon
/// until that has a frame. The larger animation is read from the reaction's file, which may still be
/// downloading: right after launch, while every available reaction's files are being fetched, or for
/// a reaction whose file left the media cache although its icon is still in the animation cache.
/// Upstream faded the item's still icon out at once, so the item, and the button it stood in for,
/// showed nothing until the download finished. The icon now goes when the larger animation reports
/// its first frame (`AnimatedStickerNode.started`); a file that never arrives leaves the icon.
/// Main thread only.
final class ReactionExpandedIconHandOver {
    private struct PendingFadeOut {
        let node: ASDisplayNode
        let duration: Double
        let completion: (() -> Void)?
    }

    private(set) var expandedAnimationHasStarted: Bool = false
    private var pending: [PendingFadeOut] = []

    init() {
    }

    var hasPendingFadeOut: Bool {
        return !self.pending.isEmpty
    }

    /// Fades `node` out once the larger animation has drawn a frame, at once if it already has.
    func fadeOutWhenExpandedAnimationStarts(_ node: ASDisplayNode, duration: Double, completion: (() -> Void)? = nil) {
        if self.expandedAnimationHasStarted {
            ReactionExpandedIconHandOver.fadeOut(node, duration: duration, completion: completion)
        } else {
            self.pending.removeAll(where: { $0.node === node })
            self.pending.append(PendingFadeOut(node: node, duration: duration, completion: completion))
        }
    }

    /// The larger animation has drawn its first frame.
    func expandedAnimationStarted() {
        if self.expandedAnimationHasStarted {
            return
        }
        self.expandedAnimationHasStarted = true
        let pending = self.pending
        self.pending.removeAll()
        for item in pending {
            ReactionExpandedIconHandOver.fadeOut(item.node, duration: item.duration, completion: item.completion)
        }
    }

    /// Whether the still icon is shown when the appear animation ends: always without a larger
    /// animation (upstream), and with one only while it has not drawn a frame.
    func showsStaticIconAfterAppearAnimation(hasExpandedAnimation: Bool) -> Bool {
        return !hasExpandedAnimation || !self.expandedAnimationHasStarted
    }

    private static func fadeOut(_ node: ASDisplayNode, duration: Double, completion: (() -> Void)?) {
        node.alpha = 0.0
        node.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration, completion: { _ in
            completion?()
        })
    }
}
