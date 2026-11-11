import XCTest
@testable import ChatRowPrep

final class ChatDustSnapshotPolicyTests: XCTestCase {
    func testASmallBubbleIsDrawnAtScaleOne() {
        XCTAssertEqual(ChatDustSnapshotPolicy.snapshotScale(forHeight: 120.0), 1.0)
        XCTAssertEqual(ChatDustSnapshotPolicy.snapshotScale(forHeight: 900.0), 1.0)
    }

    func testATallBubbleFallsBackToTheNormalDeleteAnimation() {
        XCTAssertNil(ChatDustSnapshotPolicy.snapshotScale(forHeight: 900.5))
        XCTAssertNil(ChatDustSnapshotPolicy.snapshotScale(forHeight: 1800.0))
    }

    func testTheBatchNeedsEveryBubbleEligibleAndAtLeastOne() {
        XCTAssertTrue(ChatDustSnapshotPolicy.isEligible(heights: [100.0, 900.0]))
        XCTAssertFalse(ChatDustSnapshotPolicy.isEligible(heights: [100.0, 1000.0]))
        XCTAssertFalse(ChatDustSnapshotPolicy.isEligible(heights: []))
    }
}
