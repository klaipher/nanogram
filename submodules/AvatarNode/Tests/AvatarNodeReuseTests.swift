import XCTest
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
@testable import AvatarNode

final class AvatarNodeReuseTests: XCTestCase {
    private func storedNames(_ mirror: Mirror) -> Set<String> {
        return Set(mirror.children.compactMap { $0.label })
    }
    
    func testLedgersMatchStoredProperties() {
        let node = AvatarNode(font: UIFont.systemFont(ofSize: 16.0))
        XCTAssertEqual(self.storedNames(Mirror(reflecting: node)), Set(AvatarNode.reuseLedger.keys), "AvatarNode changed its stored properties; decide for each in reuseLedger and prepareForReuse")
        XCTAssertEqual(self.storedNames(Mirror(reflecting: node.contentNode)), Set(AvatarNode.ContentNode.reuseLedger.keys), "AvatarNode.ContentNode changed its stored properties; decide for each in reuseLedger and prepareForReuse")
    }
    
    func testPrepareClearsStoryAndImage() {
        let node = AvatarNode(font: UIFont.systemFont(ofSize: 16.0))
        node.frame = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 60.0)
        _ = node.view
        let colors = AvatarNode.Colors(unseenColors: [.red, .blue], unseenCloseFriendsColors: [.green, .blue], seenColors: [.gray, .lightGray])
        let params = AvatarNode.StoryPresentationParams(colors: colors, lineWidth: 2.0, inactiveLineWidth: 1.0)
        node.setStoryStats(storyStats: AvatarNode.StoryStats(totalCount: 2, unseenCount: 1, hasUnseenCloseFriendsItems: false, hasLiveItems: false), presentationParams: params, transition: .immediate)
        node.setCustomLetters(["A"])
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4.0, height: 4.0)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0.0, y: 0.0, width: 4.0, height: 4.0))
        }
        node.imageNode.contents = image.cgImage
        XCTAssertNotNil(node.imageNode.contents)
        XCTAssertGreaterThan(node.view.subviews.count, 1)
        
        node.prepareForReuse()
        
        XCTAssertNil(node.storyStats)
        XCTAssertNil(node.storyPresentationParams)
        XCTAssertEqual(node.view.subviews.count, 1)
        XCTAssertTrue(node.view.subviews.first === node.contentNode.view)
        XCTAssertNil(node.imageNode.contents)
        XCTAssertTrue(node.canPrepareForReuse)
    }
    
    func testAnEditOverlayRefusesReuse() {
        let node = AvatarNode(font: UIFont.systemFont(ofSize: 16.0))
        node.editOverlayNode = AvatarEditOverlayNode()
        XCTAssertFalse(node.canPrepareForReuse)
    }
}
