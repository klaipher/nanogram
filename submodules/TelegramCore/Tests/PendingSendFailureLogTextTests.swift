import XCTest
@testable import TelegramCore

/// The failure-log line of a failed send request names what happens next, so a send that is sent again with a
/// fresh file reference (and then goes through) does not read as a lost message in the critical log.
final class PendingSendFailureLogTextTests: XCTestCase {
    private let context = "engine mtProtoKit, network wifi"

    func testSendingAgainWithAFreshReferenceKeepsThePrefixAndNamesTheRetry() {
        let text = pendingSendFailureLogText("message 1740", code: 400, text: "FILE_REFERENCE_EXPIRED", outcome: .sendingAgainWithFreshMedia(items: nil), context: self.context)
        XCTAssertEqual(text, "message 1740 request failed 400 FILE_REFERENCE_EXPIRED, sending again with a fresh reference or upload (once), engine mtProtoKit, network wifi")
        XCTAssertTrue(text.hasPrefix("message 1740 request failed 400 FILE_REFERENCE_EXPIRED"))
        XCTAssertFalse(text.contains("failing"))
    }

    func testGroupRetryNamesTheItemsThatGetAFreshReference() {
        let text = pendingSendFailureLogText("group of 3 messages starting at 10", code: 400, text: "FILE_REFERENCE_1_EXPIRED", outcome: .sendingAgainWithFreshMedia(items: [1]), context: self.context)
        XCTAssertEqual(text, "group of 3 messages starting at 10 request failed 400 FILE_REFERENCE_1_EXPIRED, sending again with a fresh reference or upload for item 1 (once), engine mtProtoKit, network wifi")
    }

    func testAnEmptyItemListReadsAsTheWholeSend() {
        let text = pendingSendFailureLogText("group of 2 messages starting at 5", code: 400, text: "FILEREF_INVALID", outcome: .sendingAgainWithFreshMedia(items: []), context: self.context)
        XCTAssertEqual(text, "group of 2 messages starting at 5 request failed 400 FILEREF_INVALID, sending again with a fresh reference or upload (once), engine mtProtoKit, network wifi")
    }

    func testAFinalFailureSaysSo() {
        let text = pendingSendFailureLogText("message 7", code: 400, text: "CHAT_WRITE_FORBIDDEN", outcome: .failing(afterFreshTry: false), context: self.context)
        XCTAssertEqual(text, "message 7 request failed 400 CHAT_WRITE_FORBIDDEN, failing it, engine mtProtoKit, network wifi")
    }

    func testAFailureAfterTheOneFreshReferenceTrySaysTheRetryWasUsed() {
        let text = pendingSendFailureLogText("message 7", code: 400, text: "FILE_REFERENCE_EXPIRED", outcome: .failing(afterFreshTry: true), context: self.context)
        XCTAssertEqual(text, "message 7 request failed 400 FILE_REFERENCE_EXPIRED, failing it, fresh reference or upload already tried, engine mtProtoKit, network wifi")
    }

    func testAMessageThatIsNoLongerPendingIsNotCalledAFailure() {
        let text = pendingSendFailureLogText("message 7", code: 400, text: "FILE_REFERENCE_EXPIRED", outcome: .noLongerPending, context: self.context)
        XCTAssertEqual(text, "message 7 request failed 400 FILE_REFERENCE_EXPIRED, no longer pending, engine mtProtoKit, network wifi")
    }

    func testAMissingContextLeavesNoTrailingSeparator() {
        let text = pendingSendFailureLogText("message 7", code: 400, text: "FILE_REFERENCE_EXPIRED", outcome: .noLongerPending, context: "")
        XCTAssertEqual(text, "message 7 request failed 400 FILE_REFERENCE_EXPIRED, no longer pending")
    }
}
