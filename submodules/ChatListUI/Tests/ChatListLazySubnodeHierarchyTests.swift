import XCTest
import UIKit
import AsyncDisplayKit
import Display
@testable import ChatListUI

final class ChatListLazySubnodeHierarchyTests: XCTestCase {
    private func makeNode() -> ChatListItemNode {
        return ChatListItemNode()
    }
    
    /// The children of `mainContentContainerNode` in the order they would have when nothing is lazy.
    private func mainChildren(of node: ChatListItemNode) -> [(ChatListMainContentChild, ASDisplayNode)] {
        return [
            (.title, node.titleNode),
            (.author, node.authorNode),
            (.text, node.textNode.textNode),
            (.date, node.dateNode),
            (.status, node.statusNode),
            (.pinnedIcon, node.pinnedIconNode),
            (.badge, node.badgeNode),
            (.mentionBadge, node.mentionBadgeNode),
            (.hiddenPeerIcon, node.hiddenPeerIconNode),
            (.mutedIcon, node.mutedIconNode)
        ]
    }
    
    private func lazyKind(of child: ChatListMainContentChild) -> ChatListLazySubnode? {
        for candidate in ChatListLazySubnode.allCases {
            if candidate.mainContentChild == child {
                return candidate
            }
        }
        return nil
    }
    
    private func ids(_ nodes: [ASDisplayNode]) -> [ObjectIdentifier] {
        return nodes.map { ObjectIdentifier($0) }
    }
    
    private func storedNodePropertyNames(_ node: ChatListItemNode) -> Set<String> {
        var names = Set<String>()
        for child in Mirror(reflecting: node).children {
            if let label = child.label, child.value is ASDisplayNode {
                names.insert(label)
            }
        }
        return names
    }
    
    func testSubnodeLedgerCoversEveryNodeProperty() {
        let node = self.makeNode()
        XCTAssertEqual(
            self.storedNodePropertyNames(node),
            Set(ChatListItemNode.subnodeLedger.keys),
            "a node was added to ChatListItemNode without a lazy/eager decision in subnodeLedger"
        )
    }
    
    func testLazyLedgerKeysMatchTheEnum() {
        var lazyKeys = Set<String>()
        for (key, decision) in ChatListItemNode.subnodeLedger {
            if case .lazy = decision {
                lazyKeys.insert(key)
            }
        }
        XCTAssertEqual(lazyKeys, Set(ChatListLazySubnode.allCases.map { $0.propertyName }))
    }
    
    func testRareNodesAreLeftOutAndUnloaded() {
        let node = self.makeNode()
        let rare: [ASDisplayNode] = [
            node.communityAvatarShadowNode, node.statusNode, node.pinnedIconNode, node.badgeNode,
            node.mentionBadgeNode, node.hiddenPeerIconNode, node.mutedIconNode, node.onlineNode
        ]
        for rareNode in rare {
            XCTAssertNil(rareNode.supernode)
            XCTAssertFalse(rareNode.isNodeLoaded)
        }
        let eager: [ASDisplayNode] = [
            node.contextContainer, node.mainContentContainerNode, node.avatarContainerNode, node.avatarNode,
            node.titleNode, node.authorNode, node.textNode.textNode, node.dateNode, node.separatorNode
        ]
        for eagerNode in eager {
            XCTAssertNotNil(eagerNode.supernode)
        }
        for kind in ChatListLazySubnode.allCases {
            XCTAssertFalse(node.isLazySubnodeAttached(kind))
        }
    }
    
    private let shuffles: [[ChatListMainContentChild]] = [
        [.status, .pinnedIcon, .badge, .mentionBadge, .hiddenPeerIcon, .mutedIcon],
        [.mutedIcon, .hiddenPeerIcon, .mentionBadge, .badge, .pinnedIcon, .status],
        [.badge, .mutedIcon, .status, .hiddenPeerIcon, .pinnedIcon, .mentionBadge],
        [.hiddenPeerIcon, .status, .mutedIcon, .pinnedIcon, .mentionBadge, .badge],
        [.mentionBadge, .pinnedIcon, .hiddenPeerIcon, .status, .badge, .mutedIcon]
    ]
    
    private func showInOrder(_ order: [ChatListMainContentChild], on node: ChatListItemNode) {
        for child in order {
            if let kind = self.lazyKind(of: child) {
                node.showLazySubnode(kind)
            }
        }
    }
    
    func testAnyShowOrderMatchesTheFlagOffOrder() {
        for loaded in [false, true] {
            for order in self.shuffles {
                let node = self.makeNode()
                if loaded {
                    _ = node.view
                }
                self.showInOrder(order, on: node)
                
                let shown = Set(order)
                let expectedNodes: [ASDisplayNode] = self.mainChildren(of: node).filter { entry in
                    return shown.contains(entry.0) || self.lazyKind(of: entry.0) == nil
                }.map { $0.1 }
                
                XCTAssertEqual(self.ids(node.mainContentContainerNode.subnodes ?? []), self.ids(expectedNodes), "order \(order)")
                if loaded {
                    let sublayers = node.mainContentContainerNode.layer.sublayers ?? []
                    XCTAssertEqual(sublayers.map { ObjectIdentifier($0) }, expectedNodes.map { ObjectIdentifier($0.layer) }, "layers, order \(order)")
                }
            }
        }
    }
    
    func testShowIsIdempotent() {
        let node = self.makeNode()
        node.showLazySubnode(.badge)
        node.showLazySubnode(.badge)
        node.showLazySubnode(.onlineDot)
        node.showLazySubnode(.onlineDot)
        XCTAssertEqual(node.mainContentContainerNode.subnodes?.filter { $0 === node.badgeNode }.count, 1)
        XCTAssertEqual(node.avatarNode.subnodes?.filter { $0 === node.onlineNode }.count, 1)
        XCTAssertTrue(node.isLazySubnodeAttached(.badge))
    }
    
    func testShadowGoesBelowAvatar() {
        let node = self.makeNode()
        node.showLazySubnode(.communityShadow)
        XCTAssertEqual(self.ids(node.avatarContainerNode.subnodes ?? []), self.ids([node.communityAvatarShadowNode, node.avatarNode]))
    }
    
    func testOnlineDotGateKeepsItBelowOverlays() {
        let node = self.makeNode()
        _ = node.view
        _ = node.avatarNode.view
        let story = UIView()
        node.avatarNode.view.insertSubview(story, aboveSubview: node.avatarNode.contentNode.view)
        node.showLazySubnode(.onlineDot)
        let overlay = ASImageNode()
        node.avatarNode.addSubnode(overlay)
        
        let sublayers = (node.avatarNode.layer.sublayers ?? []).map { ObjectIdentifier($0) }
        func index(_ layer: CALayer) -> Int? {
            return sublayers.firstIndex(of: ObjectIdentifier(layer))
        }
        guard let contentIndex = index(node.avatarNode.contentNode.layer),
              let storyIndex = index(story.layer),
              let onlineIndex = index(node.onlineNode.layer),
              let overlayIndex = index(overlay.layer) else {
            XCTFail("a layer is missing from the avatar")
            return
        }
        XCTAssertLessThan(contentIndex, storyIndex)
        XCTAssertLessThan(storyIndex, onlineIndex)
        XCTAssertLessThan(onlineIndex, overlayIndex)
    }
    
    func testPendingAlphaAndFrameSurviveAttach() {
        let node = self.makeNode()
        let rect = CGRect(x: 10.0, y: 20.0, width: 30.0, height: 40.0)
        let transition = ContainedViewLayoutTransition.animated(duration: 0.3, curve: .easeInOut)
        node.updateLazyAlpha(.badge, alpha: 0.0, transition: transition)
        node.updateLazyFrame(.badge, frame: rect, transition: transition)
        XCTAssertFalse(node.badgeNode.isNodeLoaded)
        
        node.showLazySubnode(.badge)
        XCTAssertEqual(node.badgeNode.alpha, 0.0)
        XCTAssertEqual(node.badgeNode.frame, rect)
        
        let other = self.makeNode()
        other.updateLazyFrame(.badge, frame: CGRect(x: CGFloat.nan, y: 0.0, width: 10.0, height: 10.0), transition: transition)
        XCTAssertEqual(other.badgeNode.frame, CGRect())
    }
}
