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
}
