import XCTest
import SwiftSignalKit
@testable import TelegramCore

final class PendingSendFailurePolicyTests: XCTestCase {
    func testClassifierTable() {
        let table: [(Int32, String, PendingSendFailureClass)] = [
            (400, "PEER_FLOOD", .permanent),
            (400, "CHAT_WRITE_FORBIDDEN", .permanent),
            (403, "USER_BANNED_IN_CHANNEL", .permanent),
            (400, "MEDIA_EMPTY", .permanent),
            (400, "MEDIA_INVALID", .permanent),
            (420, "SLOWMODE_WAIT_5", .permanent),
            (401, "AUTH_KEY_UNREGISTERED", .permanent),
            (400, "SOME_UNKNOWN_4XX", .permanent),
            (500, "INTERNAL", .transient),
            (502, "BAD_GATEWAY", .transient),
            (503, "TIMEOUT", .transient),
            (-503, "Timeout", .transient),
            (-500, "", .transient),
            (500, "PROTOCOL_ERROR_ANSWER_LOST", .transient),
            (500, "TL_PARSING_ERROR", .transient),
            (400, "PROTOCOL_ERROR_BAD_MSG_SEQNO_TOO_HIGH", .transient),
            (500, "ENGINE_SWITCHED", .transient),
            (400, "FILE_PART_3_MISSING", .reupload),
            (400, "FILE_PARTS_INVALID", .reupload),
            (400, "FILE_ID_INVALID", .reupload)
        ]
        for (code, text, expected) in table {
            XCTAssertEqual(classifyPendingSendError(code: code, text: text), expected, "\(code) \(text)")
        }
    }

    func testBackoffScheduleAndCap() {
        XCTAssertEqual(PendingSendRetryPolicy.delay(afterFailedAttempt: 1), 2.0)
        XCTAssertEqual(PendingSendRetryPolicy.delay(afterFailedAttempt: 2), 4.0)
        XCTAssertEqual(PendingSendRetryPolicy.delay(afterFailedAttempt: 3), 8.0)
        XCTAssertEqual(PendingSendRetryPolicy.delay(afterFailedAttempt: 4), 16.0)
        XCTAssertEqual(PendingSendRetryPolicy.delay(afterFailedAttempt: 5), 30.0)
        XCTAssertEqual(PendingSendRetryPolicy.delay(afterFailedAttempt: 50), 30.0)
    }

    func testPermanentErrorsFailOnTheFirstAttempt() {
        XCTAssertEqual(PendingSendRetryPolicy.decision(failureClass: .permanent, failedAttempts: 1, maximumAttempts: 5), .fail)
        XCTAssertEqual(PendingSendRetryPolicy.decision(failureClass: .reupload, failedAttempts: 1, maximumAttempts: 5), .fail)
    }

    func testTransientErrorsRetryUntilTheBudgetIsSpent() {
        XCTAssertEqual(PendingSendRetryPolicy.decision(failureClass: .transient, failedAttempts: 1, maximumAttempts: 5), .retry(after: 2.0))
        XCTAssertEqual(PendingSendRetryPolicy.decision(failureClass: .transient, failedAttempts: 4, maximumAttempts: 5), .retry(after: 16.0))
        XCTAssertEqual(PendingSendRetryPolicy.decision(failureClass: .transient, failedAttempts: 5, maximumAttempts: 5), .fail)
        XCTAssertEqual(PendingSendRetryPolicy.decision(failureClass: .transient, failedAttempts: 3, maximumAttempts: PendingSendRetryPolicy.maximumUploadAttempts), .fail)
    }

    private func runRetry(failures: Int, maximumFailures: Int, blocksRetryOnValue: Bool = false) -> (starts: Int, values: [Int], error: String?, completed: Bool) {
        let expectation = XCTestExpectation(description: "finished")
        let starts = Atomic<Int>(value: 0)
        var values: [Int] = []
        var error: String?
        var completed = false
        let source = Signal<Int, String> { subscriber in
            let n = starts.modify { $0 + 1 }
            if blocksRetryOnValue {
                subscriber.putNext(100)
            }
            if n <= failures {
                subscriber.putError("fail \(n)")
            } else {
                subscriber.putNext(n)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
        let queue = Queue()
        let disposable = (source |> pendingRetryingWithBackoff(queue: queue, decide: { _, failed in
            return failed <= maximumFailures ? 0.0 : nil
        }, blocksRetry: { $0 == 100 })).start(next: { values.append($0) }, error: { e in
            error = e
            expectation.fulfill()
        }, completed: {
            completed = true
            expectation.fulfill()
        })
        wait(for: [expectation], timeout: 5.0)
        disposable.dispose()
        return (starts.with { $0 }, values, error, completed)
    }

    func testARetryOperatorSucceedsAfterTransientFailures() {
        let result = runRetry(failures: 2, maximumFailures: 4)
        XCTAssertEqual(result.starts, 3)
        XCTAssertEqual(result.values, [3])
        XCTAssertTrue(result.completed)
        XCTAssertNil(result.error)
    }

    func testARetryOperatorGivesUpWhenTheBudgetIsSpent() {
        let result = runRetry(failures: 10, maximumFailures: 2)
        XCTAssertEqual(result.starts, 3)
        XCTAssertEqual(result.error, "fail 3")
        XCTAssertFalse(result.completed)
    }

    func testAValueThatBlocksRetryMakesTheNextErrorFinal() {
        let result = runRetry(failures: 5, maximumFailures: 4, blocksRetryOnValue: true)
        XCTAssertEqual(result.starts, 1)
        XCTAssertEqual(result.error, "fail 1")
    }

    func testPartRetryPolicy() {
        XCTAssertEqual(PendingUploadPartRetryPolicy.delay(code: 503, text: "TIMEOUT", failedAttempts: 1), 0.5)
        XCTAssertEqual(PendingUploadPartRetryPolicy.delay(code: 500, text: "PROTOCOL_ERROR_ANSWER_LOST", failedAttempts: 4), 4.0)
        XCTAssertNil(PendingUploadPartRetryPolicy.delay(code: 500, text: "INTERNAL", failedAttempts: 5))
        XCTAssertNil(PendingUploadPartRetryPolicy.delay(code: 400, text: "FILE_PART_SIZE_INVALID", failedAttempts: 1))
        XCTAssertNil(PendingUploadPartRetryPolicy.delay(code: 400, text: "MEDIA_EMPTY", failedAttempts: 1))
    }

    func testTheStallGuardFollowsTheAccountSettingUnlessAnUploadOptsOut() {
        XCTAssertTrue(requestNeedsTimeoutTimer(useRequestTimeoutTimers: true, override: nil))
        XCTAssertFalse(requestNeedsTimeoutTimer(useRequestTimeoutTimers: false, override: nil))
        XCTAssertFalse(requestNeedsTimeoutTimer(useRequestTimeoutTimers: true, override: false))
        XCTAssertFalse(requestNeedsTimeoutTimer(useRequestTimeoutTimers: false, override: true))
        XCTAssertFalse(pendingUploadPartsNeedTimeoutTimer)
    }

    func testFailureDescriptionMapping() {
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: nil), .notSentInTime)
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: "PEER_FLOOD"), .tooManyMessages)
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: "SENDING_TOO_FAST_3"), .tooManyMessages)
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: "MEDIA_EMPTY"), .mediaRejected)
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: "CHAT_WRITE_FORBIDDEN"), .notAllowed)
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: "USER_BANNED_IN_CHANNEL"), .notAllowed)
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: "internal"), .couldNotSend)
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: "PROTOCOL_ERROR_ANSWER_LOST"), .couldNotSend)
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: nil).text, "Not sent in time. Tap to retry.")
        XCTAssertEqual(pendingMessageFailureDescription(sendErrorCode: "PEER_FLOOD").text, "Too many messages")
    }
}
