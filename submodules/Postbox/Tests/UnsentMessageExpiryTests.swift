import XCTest
@testable import Postbox

final class UnsentMessageExpiryTests: XCTestCase {
    func testOnlyTheMainProcessExpiresUnsentMessages() {
        XCTAssertTrue(postboxShouldExpireUnsentMessages(isTemporary: false, isMainProcess: true))
        // The notification service, share and Siri extensions open the same database and must not fail a photo
        // that the suspended app is still uploading.
        XCTAssertFalse(postboxShouldExpireUnsentMessages(isTemporary: false, isMainProcess: false))
        XCTAssertFalse(postboxShouldExpireUnsentMessages(isTemporary: true, isMainProcess: true))
        XCTAssertFalse(postboxShouldExpireUnsentMessages(isTemporary: true, isMainProcess: false))
    }

    func testAMessageExpiresTenMinutesAfterItWasQueued() {
        XCTAssertFalse(postboxUnsentMessageIsExpired(messageTimestamp: 1_000, now: 1_599))
        XCTAssertTrue(postboxUnsentMessageIsExpired(messageTimestamp: 1_000, now: 1_600))
        XCTAssertTrue(postboxUnsentMessageIsExpired(messageTimestamp: 1_000, now: 100_000))
        XCTAssertFalse(postboxUnsentMessageIsExpired(messageTimestamp: Int32.max, now: Int32.max))
    }
}
