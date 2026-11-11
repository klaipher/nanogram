import XCTest
@testable import ChatListUI

final class ChatListMediaPreviewLayoutGateTests: XCTestCase {
    func testTheFirstLayoutRuns() {
        var gate = ChatListMediaPreviewLayoutGate<Int>()
        XCTAssertTrue(gate.shouldLayout(size: CGSize(width: 36.0, height: 36.0), mediaId: 1))
    }

    func testTheSameSizeAndMediaIsSkipped() {
        var gate = ChatListMediaPreviewLayoutGate<Int>()
        _ = gate.shouldLayout(size: CGSize(width: 36.0, height: 36.0), mediaId: 1)
        XCTAssertFalse(gate.shouldLayout(size: CGSize(width: 36.0, height: 36.0), mediaId: 1))
        XCTAssertFalse(gate.shouldLayout(size: CGSize(width: 36.0, height: 36.0), mediaId: 1))
    }

    func testAChangedSizeOrMediaRunsAgain() {
        var gate = ChatListMediaPreviewLayoutGate<Int>()
        _ = gate.shouldLayout(size: CGSize(width: 36.0, height: 36.0), mediaId: 1)
        XCTAssertTrue(gate.shouldLayout(size: CGSize(width: 40.0, height: 40.0), mediaId: 1))
        XCTAssertTrue(gate.shouldLayout(size: CGSize(width: 40.0, height: 40.0), mediaId: 2))
        XCTAssertFalse(gate.shouldLayout(size: CGSize(width: 40.0, height: 40.0), mediaId: 2))
    }
}
