import XCTest
import CallKit
@testable import TelegramCallsUI

final class CallKitReportFailureTests: XCTestCase {
    private let domain = CXErrorDomainIncomingCall

    func testUnknownAndUnentitledFallBackToRingingWithoutCallKit() {
        XCTAssertEqual(callKitReportFailureAction(domain: self.domain, code: 0), .fallBackToNotification)
        XCTAssertEqual(callKitReportFailureAction(domain: self.domain, code: 1), .fallBackToNotification)
    }

    func testAForeignErrorDomainIsAnUnknownFailure() {
        XCTAssertEqual(callKitReportFailureAction(domain: "NSPOSIXErrorDomain", code: 5), .fallBackToNotification)
    }

    func testFilteredCallersAreHungUp() {
        for code in [4, 5, 6, 7] {
            XCTAssertEqual(callKitReportFailureAction(domain: self.domain, code: code), .hangUp, "code \(code)")
        }
    }

    func testDoNotDisturbAndAnAlreadyReportedCallAreLeftToCallKit() {
        XCTAssertEqual(callKitReportFailureAction(domain: self.domain, code: 3), .keepRinging)
        XCTAssertEqual(callKitReportFailureAction(domain: self.domain, code: -3), .keepRinging)
        XCTAssertEqual(callKitReportFailureAction(domain: self.domain, code: 2), .keepRinging)
    }
}
