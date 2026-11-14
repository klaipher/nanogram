import Foundation
import XCTest
@testable import TelegramCore

final class ProbeIncomingCallTests: XCTestCase {
    func testDeclinedAndInvalidCallsAreEnded() {
        XCTAssertEqual(incomingCallProbeResult(errorCode: 400, errorDescription: "CALL_ALREADY_DECLINED"), .ended("rpc 400 CALL_ALREADY_DECLINED"))
        XCTAssertEqual(incomingCallProbeResult(errorCode: 400, errorDescription: "CALL_PEER_INVALID"), .ended("rpc 400 CALL_PEER_INVALID"))
    }

    func testOtherFailuresSayNothingAboutTheCall() {
        XCTAssertEqual(incomingCallProbeResult(errorCode: 420, errorDescription: "FLOOD_WAIT_3"), .unknown)
        XCTAssertEqual(incomingCallProbeResult(errorCode: 500, errorDescription: "INTERNAL"), .unknown)
        XCTAssertEqual(incomingCallProbeResult(errorCode: 401, errorDescription: "AUTH_KEY_UNREGISTERED"), .unknown)
        XCTAssertEqual(incomingCallProbeResult(errorCode: 0, errorDescription: nil), .unknown)
    }

    func testEndedWithoutADescriptionStillNamesTheCode() {
        XCTAssertEqual(incomingCallProbeResult(errorCode: 400, errorDescription: nil), .ended("rpc 400"))
    }
}
