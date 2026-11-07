import XCTest
import UIKit
import AsyncDisplayKit
import Display
@testable import ChatListUI

final class ChatListBadgeNodeReuseTests: XCTestCase {
    private func apply(_ node: ChatListBadgeNode, _ content: ChatListBadgeContent) {
        let layout = node.asyncLayout()
        let (_, apply) = layout(CGSize(width: 100.0, height: 20.0), 20.0, UIFont.systemFont(ofSize: 14.0), nil, content)
        apply(false, false)
    }
    
    private func text(_ string: String) -> ChatListBadgeContent {
        return .text(NSAttributedString(string: string, font: UIFont.systemFont(ofSize: 14.0), textColor: .white))
    }
    
    func testReusedBadgeIsHiddenByEmptyContentAfterAHiddenBadge() {
        let node = ChatListBadgeNode()
        self.apply(node, self.text("3"))
        XCTAssertFalse(node.isHidden)
        self.apply(node, .none)
        XCTAssertTrue(node.isHidden)
        
        // The row is pooled and reset, then reused for a chat without unread messages.
        node.resetForRowReuse()
        XCTAssertFalse(node.isHidden)
        self.apply(node, .none)
        XCTAssertTrue(node.isHidden)
        XCTAssertNil(node.backgroundNode.image)
    }
    
    func testResetForgetsTheStaleBadgeContent() {
        let node = ChatListBadgeNode()
        self.apply(node, self.text("7"))
        node.resetForRowReuse()
        XCTAssertEqual(node.textNode.alpha, 1.0)
        XCTAssertNil(node.backgroundNode.image)
        self.apply(node, self.text("7"))
        XCTAssertFalse(node.isHidden)
        XCTAssertEqual(node.textNode.alpha, 1.0)
    }
}
