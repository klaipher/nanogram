import XCTest
@testable import ChatListUI

final class ChatListSynchronousLoadingPolicyTests: XCTestCase {
    private func prefers(first: Bool = false, filter: Bool = false, scroll: Bool = false, inserted: Int = 0) -> Bool {
        return ChatListSynchronousLoadingPolicy.prefersSynchronousResourceLoading(isFirstTransition: first, filterChanged: filter, scrollsToItem: scroll, insertedCount: inserted)
    }

    func testIncrementalUpdatesLoadAsynchronously() {
        XCTAssertFalse(self.prefers())
        XCTAssertFalse(self.prefers(inserted: 1))
        XCTAssertFalse(self.prefers(inserted: ChatListSynchronousLoadingPolicy.bulkInsertThreshold))
    }

    func testFirstContentFolderSwitchAndJumpStaySynchronous() {
        XCTAssertTrue(self.prefers(first: true))
        XCTAssertTrue(self.prefers(filter: true))
        XCTAssertTrue(self.prefers(scroll: true))
    }

    func testBulkInsertStaysSynchronous() {
        XCTAssertTrue(self.prefers(inserted: ChatListSynchronousLoadingPolicy.bulkInsertThreshold + 1))
        XCTAssertTrue(self.prefers(inserted: 40))
    }
}
