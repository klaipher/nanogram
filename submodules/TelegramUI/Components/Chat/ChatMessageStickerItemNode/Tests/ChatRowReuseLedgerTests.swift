import XCTest
import UIKit
import AsyncDisplayKit
import Display
import ChatMessageItemView
@testable import ChatMessageStickerItemNode

/// The sticker row is the one view type certified for "Chat rows: reuse row views". These tests keep its reset complete:
/// every stored property of the class chain must have a decision in a ledger, and the reset must put the state that can
/// be set from outside back.
final class ChatRowReuseLedgerTests: XCTestCase {
    private func storedNames(_ mirror: Mirror?) -> Set<String> {
        guard let mirror else {
            return []
        }
        return Set(mirror.children.compactMap { $0.label })
    }

    func testEveryStoredPropertyOfTheStickerRowHasADecision() {
        let node = ChatMessageStickerItemNode(rotated: true)
        let mirror = Mirror(reflecting: node)
        XCTAssertEqual(self.storedNames(mirror), Set(ChatMessageStickerItemNode.stickerRowReuseLedger.keys), "a property was added to or removed from ChatMessageStickerItemNode without updating stickerRowReuseLedger and prepareForRowReuse")
        XCTAssertEqual(self.storedNames(mirror.superclassMirror), Set(ChatMessageItemView.rowReuseBaseLedger.keys), "a property was added to or removed from ChatMessageItemView without updating rowReuseBaseLedger and prepareForRowReuse")
        XCTAssertEqual(self.storedNames(mirror.superclassMirror?.superclassMirror), Set(ChatMessageItemView.listViewItemNodeLedger.keys), "ListViewItemNode (Display) changed its stored properties; decide for each whether the reset must clear it")
    }

    func testOnlyTheStickerRowIsCertifiedHere() {
        XCTAssertFalse(ChatMessageItemView.supportsRowReuse)
        XCTAssertTrue(ChatMessageStickerItemNode.supportsRowReuse)
    }

    func testTheResetClearsEverythingThatCanBeSet() {
        let node = ChatMessageStickerItemNode(rotated: true)
        let contentNode = node.contextSourceNode.contentNode
        let originalSubnodes = contentNode.subnodes ?? []
        XCTAssertEqual(originalSubnodes.count, 3)
        let originalPlaceholder = originalSubnodes.first

        node.safeInsets = UIEdgeInsets(top: 1.0, left: 2.0, bottom: 3.0, right: 4.0)
        node.scrollTiltProvider = { _ in 1.0 }
        node.awaitingAppliedReaction = (nil, {})
        node.isHighlightedInOverlay = true
        node.hostOwnsFrame = true
        node.transitionOffset = 12.0
        node.playedEffectAnimation = true
        node.visibility = .visible(1.0, CGRect(x: 0.0, y: 0.0, width: 10.0, height: 10.0))
        node.highlightedState = true
        node.currentSwipeToReplyTranslation = 30.0
        node.wasPending = true
        node.didChangeFromPendingToSent = true
        node.forceStopAnimations = true
        node.enableSynchronousImageApply = true
        node.playedSwipeToReplyHaptic = true
        node.imageUpdatedFirstTime = false
        node.layer.add(CABasicAnimation(keyPath: "opacity"), forKey: "test")
        node.imageNode.layer.add(CABasicAnimation(keyPath: "opacity"), forKey: "test")

        XCTAssertTrue(node.prepareForRowReuse())

        XCTAssertNil(node.item)
        XCTAssertNil(node.accessibilityData)
        XCTAssertEqual(node.safeInsets, UIEdgeInsets())
        XCTAssertNil(node.scrollTiltProvider)
        XCTAssertNil(node.awaitingAppliedReaction)
        XCTAssertFalse(node.isHighlightedInOverlay)
        XCTAssertFalse(node.hostOwnsFrame)
        XCTAssertEqual(node.transitionOffset, 0.0)
        XCTAssertFalse(node.playedEffectAnimation)
        XCTAssertTrue(node.visibility == .none)
        XCTAssertTrue(node.attachedHeaderNodes.isEmpty)
        XCTAssertFalse(node.highlightedState)
        XCTAssertEqual(node.currentSwipeToReplyTranslation, 0.0)
        XCTAssertFalse(node.wasPending)
        XCTAssertFalse(node.didChangeFromPendingToSent)
        XCTAssertFalse(node.forceStopAnimations)
        XCTAssertFalse(node.enableSynchronousImageApply)
        XCTAssertFalse(node.playedSwipeToReplyHaptic)
        XCTAssertTrue(node.imageUpdatedFirstTime)
        XCTAssertNil(node.telegramFile)
        XCTAssertNil(node.appliedForwardInfo)
        XCTAssertNil(node.currentSwipeAction)
        XCTAssertNil(node.visibilityStatus)
        XCTAssertNil(node.layer.animationKeys())
        XCTAssertNil(node.imageNode.layer.animationKeys())

        // The placeholder is a new node in the same place: it keeps the outline of the previous sticker otherwise.
        let subnodes = contentNode.subnodes ?? []
        XCTAssertEqual(subnodes.count, 3)
        XCTAssertTrue(subnodes.first !== originalPlaceholder)
        XCTAssertTrue(subnodes.count > 1 && subnodes[1] === node.imageNode)
    }

    func testARowExtractedIntoAContextMenuIsNotReset() {
        let node = ChatMessageStickerItemNode(rotated: true)
        node.contextSourceNode.isExtractedToContextPreview = true
        node.playedSwipeToReplyHaptic = true
        XCTAssertFalse(node.prepareForRowReuse())
        XCTAssertTrue(node.playedSwipeToReplyHaptic, "a refused reset must not touch the row")
    }
}
