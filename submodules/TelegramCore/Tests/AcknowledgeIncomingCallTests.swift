import Foundation
import XCTest
@testable import TelegramApi
@testable import TelegramCore

final class AcknowledgeIncomingCallTests: XCTestCase {
    func testRequestIsPhoneReceivedCallForTheCall() {
        let request = _internal_incomingCallAcknowledgementRequest(id: 123456789, accessHash: -987654321)
        let expected = Api.functions.phone.receivedCall(peer: .inputPhoneCall(.init(id: 123456789, accessHash: -987654321)))
        XCTAssertEqual(request.0.name, "phone.receivedCall")
        XCTAssertEqual(request.1.makeData(), expected.1.makeData())
    }

    func testRequestDiffersPerCall() {
        let first = _internal_incomingCallAcknowledgementRequest(id: 1, accessHash: 2)
        let second = _internal_incomingCallAcknowledgementRequest(id: 1, accessHash: 3)
        XCTAssertNotEqual(first.1.makeData(), second.1.makeData())
    }

    func testDeclineIsPhoneDiscardCallWithHangUp() {
        let request = _internal_declineIncomingCallRequest(id: 11, accessHash: 22, isVideo: false)
        let expected = Api.functions.phone.discardCall(flags: 0, peer: .inputPhoneCall(.init(id: 11, accessHash: 22)), duration: 0, reason: .phoneCallDiscardReasonHangup, connectionId: 0)
        XCTAssertEqual(request.0.name, "phone.discardCall")
        XCTAssertEqual(request.1.makeData(), expected.1.makeData())
    }

    func testDeclineOfAVideoCallSetsTheVideoFlag() {
        let audio = _internal_declineIncomingCallRequest(id: 11, accessHash: 22, isVideo: false)
        let video = _internal_declineIncomingCallRequest(id: 11, accessHash: 22, isVideo: true)
        XCTAssertNotEqual(audio.1.makeData(), video.1.makeData())
    }
}
