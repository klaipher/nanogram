import XCTest
import UIKit
import AsyncDisplayKit
@testable import Display

final class ListViewItemNodePoolResetTests: XCTestCase {
    private func storedNames(_ mirror: Mirror?) -> Set<String> {
        guard let mirror else {
            return []
        }
        return Set(mirror.children.compactMap { $0.label })
    }
    
    func testLedgerMatchesStoredProperties() {
        let node = ListViewItemNode(layerBacked: false)
        let mirror = Mirror(reflecting: node)
        // Mirror of the ListViewItemNode class itself: the subclass chain starts at ASDisplayNode below it.
        XCTAssertEqual(self.storedNames(mirror), Set(ListViewItemNode.poolResetLedger.keys), "ListViewItemNode changed its stored properties; decide for each in poolResetLedger and prepareForPoolReuse")
    }
    
    func testResetClearsListState() {
        let node = ListViewItemNode(layerBacked: false)
        node.index = 4
        node.addApparentHeightAnimation(120.0, duration: 0.3, beginAt: 0.0)
        XCTAssertNotNil(node.animationForKey("apparentHeight"))
        node.isHighlightedInOverlay = true
        node.stickyHeaderBandTrim = 5.0
        node.tempHeaderSpaceAffinities[ListViewItemNode.HeaderId(space: 1, id: 2)] = 3
        node.headerSpaceAffinities[ListViewItemNode.HeaderId(space: 1, id: 2)] = 3
        node.transitionOffset = 7.0
        node.apparentHeight = 50.0
        node.visibility = .visible(1.0, CGRect(x: 0.0, y: 0.0, width: 10.0, height: 10.0))
        node.hostOwnsFrame = true
        
        node.prepareForPoolReuse()
        
        XCTAssertNil(node.index)
        XCTAssertNil(node.animationForKey("apparentHeight"))
        XCTAssertNil(node.apparentHeightTransition)
        XCTAssertFalse(node.isHighlightedInOverlay)
        XCTAssertEqual(node.stickyHeaderBandTrim, 0.0)
        XCTAssertTrue(node.tempHeaderSpaceAffinities.isEmpty)
        XCTAssertTrue(node.headerSpaceAffinities.isEmpty)
        XCTAssertEqual(node.transitionOffset, 0.0)
        XCTAssertEqual(node.apparentHeight, 0.0)
        XCTAssertTrue(node.visibility == .none)
        XCTAssertFalse(node.hostOwnsFrame)
        XCTAssertTrue(node.attachedHeaderNodes.isEmpty)
        XCTAssertNil(node.accessoryItemNode)
    }
}
