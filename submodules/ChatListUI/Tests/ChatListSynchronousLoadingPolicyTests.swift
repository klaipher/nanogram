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

    func testBulkInsertWhileScrollingLoadsAsynchronouslyWhenTheSwitchIsOn() {
        let bulk = ChatListSynchronousLoadingPolicy.bulkInsertThreshold + 1
        XCTAssertFalse(ChatListSynchronousLoadingPolicy.prefersSynchronousResourceLoading(isFirstTransition: false, filterChanged: false, scrollsToItem: false, insertedCount: bulk, userIsScrolling: true, asyncWhileScrolling: true))
    }

    func testBulkInsertWhileScrollingStaysSynchronousWhenTheSwitchIsOff() {
        let bulk = ChatListSynchronousLoadingPolicy.bulkInsertThreshold + 1
        XCTAssertTrue(ChatListSynchronousLoadingPolicy.prefersSynchronousResourceLoading(isFirstTransition: false, filterChanged: false, scrollsToItem: false, insertedCount: bulk, userIsScrolling: true, asyncWhileScrolling: false))
    }

    func testBulkInsertWhileNotScrollingStaysSynchronous() {
        let bulk = ChatListSynchronousLoadingPolicy.bulkInsertThreshold + 1
        XCTAssertTrue(ChatListSynchronousLoadingPolicy.prefersSynchronousResourceLoading(isFirstTransition: false, filterChanged: false, scrollsToItem: false, insertedCount: bulk, userIsScrolling: false, asyncWhileScrolling: true))
    }

    func testFirstContentFolderSwitchAndJumpStaySynchronousWhileScrolling() {
        for (first, filter, scroll) in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertTrue(ChatListSynchronousLoadingPolicy.prefersSynchronousResourceLoading(isFirstTransition: first, filterChanged: filter, scrollsToItem: scroll, insertedCount: 0, userIsScrolling: true, asyncWhileScrolling: true))
        }
    }
}
