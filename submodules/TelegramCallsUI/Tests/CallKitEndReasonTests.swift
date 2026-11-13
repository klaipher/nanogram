import XCTest
import CallKit
import TelegramCore
@testable import TelegramCallsUI

final class CallKitEndReasonTests: XCTestCase {
    func testAMissedCallIsUnanswered() {
        XCTAssertEqual(callKitEndedReason(.ended(.missed)), .unanswered)
    }

    func testAnErrorIsAFailure() {
        XCTAssertEqual(callKitEndedReason(.error(.disconnected)), .failed)
    }

    func testAnEndedCallIsRemoteEnded() {
        XCTAssertEqual(callKitEndedReason(.ended(.hungUp)), .remoteEnded)
        XCTAssertEqual(callKitEndedReason(.ended(.busy)), .remoteEnded)
        XCTAssertEqual(callKitEndedReason(.ended(.switchedToConference(slug: "a"))), .remoteEnded)
        XCTAssertEqual(callKitEndedReason(nil), .remoteEnded)
    }
}
