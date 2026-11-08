import XCTest
import UIKit
import AsyncDisplayKit
import Display
@testable import ChatListUI

final class ChatListRowReuseResetTests: XCTestCase {
    private func makeNode() -> ChatListItemNode {
        return ChatListItemNode()
    }
    
    private func makeImage() -> UIImage {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 2.0, height: 2.0), true, 1.0)
        UIColor.red.setFill()
        UIRectFill(CGRect(x: 0.0, y: 0.0, width: 2.0, height: 2.0))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
    
    func testABareNodeIsRefusedForMissingItem() {
        let node = self.makeNode()
        XCTAssertEqual(node.rowReuseRefusal(), .notEligible)
        XCTAssertFalse(node.prepareForRowReuse())
    }
    
    func testRefusalsLeaveTheRowUntouched() {
        // Tainted.
        do {
            let node = self.makeNode()
            node.isRowReuseTainted = true
            node.currentTextLeftCutout = 5.0
            XCTAssertEqual(node.rowReuseRefusalIgnoringEligibilityForTesting(), .tainted)
            XCTAssertFalse(node.prepareForRowReuseIgnoringEligibilityForTesting())
            XCTAssertEqual(node.currentTextLeftCutout, 5.0)
        }
        // Highlighted.
        do {
            let node = self.makeNode()
            node.setHighlighted(true, at: CGPoint(), animated: false)
            node.currentTextLeftCutout = 5.0
            XCTAssertEqual(node.rowReuseRefusalIgnoringEligibilityForTesting(), .highlighted)
            XCTAssertFalse(node.prepareForRowReuseIgnoringEligibilityForTesting())
            XCTAssertEqual(node.currentTextLeftCutout, 5.0)
        }
        // A layer animation in the subtree.
        do {
            let node = self.makeNode()
            _ = node.view
            node.titleNode.layer.add(CABasicAnimation(keyPath: "opacity"), forKey: "test")
            node.currentTextLeftCutout = 5.0
            XCTAssertEqual(node.rowReuseRefusalIgnoringEligibilityForTesting(), .animating)
            XCTAssertFalse(node.prepareForRowReuseIgnoringEligibilityForTesting())
            XCTAssertEqual(node.currentTextLeftCutout, 5.0)
        }
        // Node state a removal animation leaves behind.
        do {
            let node = self.makeNode()
            node.zPosition = -1.0
            node.currentTextLeftCutout = 5.0
            XCTAssertEqual(node.rowReuseRefusalIgnoringEligibilityForTesting(), .nodeState)
            XCTAssertFalse(node.prepareForRowReuseIgnoringEligibilityForTesting())
            XCTAssertEqual(node.currentTextLeftCutout, 5.0)
        }
        // Typing indicator shown.
        do {
            let node = self.makeNode()
            node.addSubnode(node.inputActivitiesNode)
            node.currentTextLeftCutout = 5.0
            XCTAssertEqual(node.rowReuseRefusalIgnoringEligibilityForTesting(), .typing)
            XCTAssertFalse(node.prepareForRowReuseIgnoringEligibilityForTesting())
            XCTAssertEqual(node.currentTextLeftCutout, 5.0)
        }
    }
    
    func testAnOrdinaryRowPassesTheRefusals() {
        let node = self.makeNode()
        XCTAssertNil(node.rowReuseRefusalIgnoringEligibilityForTesting())
        _ = node.view
        XCTAssertNil(node.rowReuseRefusalIgnoringEligibilityForTesting())
    }
    
    func testResetRestoresDefaults() {
        let node = self.makeNode()
        _ = node.view
        
        let fixed: [ASDisplayNode] = [
            node.titleNode, node.dateNode, node.authorNode, node.avatarContainerNode, node.mainContentContainerNode,
            node.separatorNode, node.contextContainer, node.inputActivitiesNode, node.pinnedIconNode, node.mutedIconNode,
            node.badgeNode, node.onlineNode
        ]
        let defaults = fixed.map { ($0, $0.alpha, $0.isHidden, $0.frame) }
        
        node.titleNode.alpha = 0.3
        node.dateNode.isHidden = true
        node.authorNode.alpha = 0.5
        node.avatarContainerNode.frame = CGRect(x: 10.0, y: 10.0, width: 20.0, height: 20.0)
        node.pinnedIconNode.image = self.makeImage()
        node.mutedIconNode.alpha = 0.7
        node.badgeNode.isHidden = true
        node.inputActivitiesNode.alpha = 1.0
        node.titleNode.transform = CATransform3DMakeScale(2.0, 2.0, 1.0)
        
        let secretIconNode = ASImageNode()
        node.secretIconNode = secretIconNode
        node.mainContentContainerNode.addSubnode(secretIconNode)
        let dateStatusIconNode = ASImageNode()
        node.dateStatusIconNode = dateStatusIconNode
        node.mainContentContainerNode.addSubnode(dateStatusIconNode)
        let trailingTextBadgeNode = TextNode()
        node.trailingTextBadgeNode = trailingTextBadgeNode
        node.mainContentContainerNode.addSubnode(trailingTextBadgeNode)
        let trailingTextBadgeBackground = UIImageView()
        node.trailingTextBadgeBackground = trailingTextBadgeBackground
        node.mainContentContainerNode.view.addSubview(trailingTextBadgeBackground)
        let dateDisclosureIconView = UIImageView()
        node.dateDisclosureIconView = dateDisclosureIconView
        node.mainContentContainerNode.view.addSubview(dateDisclosureIconView)
        node.addSubnode(node.forwardedIconNode)
        
        node.onlineIsVoiceChat = true
        node.currentOnline = true
        node.cachedDataPeerId = nil
        node.currentTextLeftCutout = 5.0
        node.nextSideListHighlightKey = .allThreads
        node.visibility = .visible(1.0, CGRect(x: 0.0, y: 0.0, width: 10.0, height: 10.0))
        
        XCTAssertTrue(node.prepareForRowReuseIgnoringEligibilityForTesting())
        
        for (subnode, alpha, isHidden, frame) in defaults {
            XCTAssertEqual(subnode.alpha, alpha)
            XCTAssertEqual(subnode.isHidden, isHidden)
            XCTAssertEqual(subnode.frame, frame)
        }
        XCTAssertTrue(CATransform3DIsIdentity(node.titleNode.transform))
        XCTAssertNil(node.pinnedIconNode.image)
        
        XCTAssertNil(node.secretIconNode)
        XCTAssertNil(secretIconNode.supernode)
        XCTAssertNil(node.dateStatusIconNode)
        XCTAssertNil(dateStatusIconNode.supernode)
        XCTAssertNil(node.trailingTextBadgeNode)
        XCTAssertNil(trailingTextBadgeNode.supernode)
        XCTAssertNil(node.trailingTextBadgeBackground)
        XCTAssertNil(trailingTextBadgeBackground.superview)
        XCTAssertNil(node.dateDisclosureIconView)
        XCTAssertNil(dateDisclosureIconView.superview)
        XCTAssertNil(node.forwardedIconNode.supernode)
        
        XCTAssertFalse(node.onlineIsVoiceChat)
        XCTAssertNil(node.currentOnline)
        XCTAssertEqual(node.currentTextLeftCutout, 0.0)
        XCTAssertNil(node.nextSideListHighlightKey)
        XCTAssertNil(node.item)
        XCTAssertNil(node.layoutParams)
        XCTAssertTrue(node.visibility == .none)
        XCTAssertNil(node.view.accessibilityLabel)
        XCTAssertNil(node.rowReuseRefusalIgnoringEligibilityForTesting())
    }
}
