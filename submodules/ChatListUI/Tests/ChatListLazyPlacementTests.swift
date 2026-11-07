import XCTest
@testable import ChatListUI

final class ChatListLazyPlacementTests: XCTestCase {
    private let eager: Set<ChatListMainContentChild> = [.title, .author, .text, .date]
    private let lazyChildren: [ChatListMainContentChild] = [.status, .pinnedIcon, .badge, .mentionBadge, .hiddenPeerIcon, .mutedIcon]
    
    func testWithOnlyEagerChildrenEveryLazyChildGoesAboveDate() {
        for child in self.lazyChildren {
            XCTAssertEqual(chatListLazyPlacement(for: child, attached: self.eager), .above(.date), "\(child)")
        }
    }
    
    func testMutedGoesAbovePinnedWhenPinnedIsAttached() {
        var attached = self.eager
        attached.insert(.pinnedIcon)
        XCTAssertEqual(chatListLazyPlacement(for: .mutedIcon, attached: attached), .above(.pinnedIcon))
    }
    
    func testTextIsNeverAnAnchor() {
        XCTAssertEqual(chatListLazyPlacement(for: .status, attached: [.text]), .first)
        XCTAssertEqual(chatListLazyPlacement(for: .status, attached: [.title, .text]), .above(.title))
    }
    
    private func permutations(_ items: [ChatListMainContentChild]) -> [[ChatListMainContentChild]] {
        if items.count <= 1 {
            return [items]
        }
        var result: [[ChatListMainContentChild]] = []
        for index in 0 ..< items.count {
            var rest = items
            let head = rest.remove(at: index)
            for tail in self.permutations(rest) {
                result.append([head] + tail)
            }
        }
        return result
    }
    
    func testEveryAttachOrderGivesTheInitOrder() {
        let expected = ["title", "author", "text", "date", "status", "pinnedIcon", "badge", "mentionBadge", "hiddenPeerIcon", "mutedIcon", "dyn1"]
        let all = self.permutations(self.lazyChildren)
        XCTAssertEqual(all.count, 720)
        for order in all {
            var container: [String] = ["title", "author", "text", "date", "dyn1"]
            var attached = self.eager
            for child in order {
                switch chatListLazyPlacement(for: child, attached: attached) {
                case let .above(anchor):
                    guard let index = container.firstIndex(of: "\(anchor)") else {
                        XCTFail("anchor \(anchor) is not in the container")
                        return
                    }
                    container.insert("\(child)", at: index + 1)
                case .first:
                    container.insert("\(child)", at: 0)
                }
                attached.insert(child)
            }
            XCTAssertEqual(container, expected, "order \(order)")
        }
    }
    
    func testWithTextMovedToTheEndLazyChildrenStayBelowIt() {
        var container: [String] = ["title", "author", "date", "text"]
        var attached = self.eager
        for child in self.lazyChildren {
            switch chatListLazyPlacement(for: child, attached: attached) {
            case let .above(anchor):
                guard let index = container.firstIndex(of: "\(anchor)") else {
                    XCTFail("anchor \(anchor) is not in the container")
                    return
                }
                container.insert("\(child)", at: index + 1)
            case .first:
                container.insert("\(child)", at: 0)
            }
            attached.insert(child)
        }
        guard let textIndex = container.firstIndex(of: "text") else {
            XCTFail("text is missing")
            return
        }
        for child in self.lazyChildren {
            guard let index = container.firstIndex(of: "\(child)") else {
                XCTFail("\(child) is missing")
                return
            }
            XCTAssertLessThan(index, textIndex, "\(child)")
        }
    }
}
