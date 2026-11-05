import Foundation
import XCTest
@testable import MediaAssetsContext

final class DeferredAssetRequestTests: XCTestCase {
    func testCancelAfterStartCancelsTheIssuedToken() {
        let deferred = DeferredAssetRequest<Int>()
        var cancelled: [Int] = []
        deferred.start(request: { 7 }, cancelRequest: { cancelled.append($0) })
        deferred.cancel(cancelRequest: { cancelled.append($0) })
        XCTAssertEqual(cancelled, [7])
    }

    func testCancelBeforeStartIssuesNoRequest() {
        let deferred = DeferredAssetRequest<Int>()
        var issued = 0
        var cancelled: [Int] = []
        deferred.cancel(cancelRequest: { cancelled.append($0) })
        deferred.start(request: { issued += 1; return 1 }, cancelRequest: { cancelled.append($0) })
        XCTAssertEqual(issued, 0)
        XCTAssertTrue(cancelled.isEmpty)
    }

    func testCancelWhileTheRequestIsBeingIssuedCancelsItAfterwards() {
        let deferred = DeferredAssetRequest<Int>()
        var cancelled: [Int] = []
        deferred.start(request: {
            deferred.cancel(cancelRequest: { cancelled.append($0) })
            return 5
        }, cancelRequest: { cancelled.append($0) })
        XCTAssertEqual(cancelled, [5])
    }

    func testSecondCancelDoesNotCancelTwice() {
        let deferred = DeferredAssetRequest<Int>()
        var cancelled: [Int] = []
        deferred.start(request: { 3 }, cancelRequest: { cancelled.append($0) })
        deferred.cancel(cancelRequest: { cancelled.append($0) })
        deferred.cancel(cancelRequest: { cancelled.append($0) })
        XCTAssertEqual(cancelled, [3])
    }
}
