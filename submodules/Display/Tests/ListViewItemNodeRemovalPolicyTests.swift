import XCTest
@testable import Display

final class ListViewItemNodeRemovalPolicyTests: XCTestCase {
    func testOnlyLiveNonAnimatedRemovalsAreOffered() {
        XCTAssertTrue(ListViewItemNodeRemovalPolicy.shouldOffer(wasLive: true, animated: false))
        XCTAssertFalse(ListViewItemNodeRemovalPolicy.shouldOffer(wasLive: true, animated: true))
        XCTAssertFalse(ListViewItemNodeRemovalPolicy.shouldOffer(wasLive: false, animated: false))
        XCTAssertFalse(ListViewItemNodeRemovalPolicy.shouldOffer(wasLive: false, animated: true))
    }
}
