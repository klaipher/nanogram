import XCTest
import Display
@testable import ChatListUI

final class ChatListRowReuseLedgerTests: XCTestCase {
    private func storedNames(_ mirror: Mirror?) -> Set<String> {
        guard let mirror else {
            return []
        }
        return Set(mirror.children.compactMap { $0.label })
    }
    
    func testEveryStoredPropertyHasADecision() {
        let node = ChatListItemNode()
        let mirror = Mirror(reflecting: node)
        XCTAssertEqual(self.storedNames(mirror), Set(ChatListItemNode.rowReuseLedger.keys), "a property was added to or removed from ChatListItemNode without updating rowReuseLedger and prepareForRowReuse")
        XCTAssertEqual(self.storedNames(mirror.superclassMirror), Set(ChatListItemNode.revealOptionsLedger.keys), "a property was added to or removed from ItemListRevealOptionsItemNode without updating revealOptionsLedger")
        XCTAssertEqual(self.storedNames(mirror.superclassMirror?.superclassMirror), Set(ListViewItemNode.poolResetLedger.keys), "a property was added to or removed from ListViewItemNode without updating poolResetLedger and prepareForPoolReuse")
    }
}
