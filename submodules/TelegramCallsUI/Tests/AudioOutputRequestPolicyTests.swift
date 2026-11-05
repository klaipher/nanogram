import XCTest
@testable import TelegramCallsUI

final class AudioOutputRequestPolicyTests: XCTestCase {
    func testFirstRequestIsApplied() {
        XCTAssertEqual(audioOutputRequestDecision(requested: "speaker", lastRequested: nil, reported: "builtin"), .apply)
    }

    func testRequestForTheRouteTheSessionReportsIsSkipped() {
        XCTAssertEqual(audioOutputRequestDecision(requested: "speaker", lastRequested: "speaker", reported: "speaker"), .skipAlreadyInEffect)
    }

    func testRepeatedRequestIsAppliedAgainWhenTheFirstOneHadNoEffect() {
        XCTAssertEqual(audioOutputRequestDecision(requested: "speaker", lastRequested: "speaker", reported: "builtin"), .apply)
    }

    func testRequestIsAppliedWhenTheSessionHasReportedNothing() {
        XCTAssertEqual(audioOutputRequestDecision(requested: "speaker", lastRequested: "speaker", reported: nil), .apply)
    }

    func testChangingTheRouteIsAlwaysApplied() {
        XCTAssertEqual(audioOutputRequestDecision(requested: "builtin", lastRequested: "speaker", reported: "speaker"), .apply)
        XCTAssertEqual(audioOutputRequestDecision(requested: "builtin", lastRequested: "speaker", reported: "builtin"), .apply)
    }

    func testNoEarlierRequestIsAppliedEvenWhenTheSessionReportsTheSameRoute() {
        XCTAssertEqual(audioOutputRequestDecision(requested: "builtin", lastRequested: nil, reported: "builtin"), .apply)
    }

    func testLogLineNamesRequestStoredValueAndReportedRoute() {
        let line = audioOutputRequestLogLine(requested: "speaker", lastRequested: "speaker", reported: "builtin", decision: .apply, hasSessionControl: true, viaCallKit: true)
        XCTAssertEqual(line, "audio output request speaker (last request speaker, session reports builtin, CallKit): applying")
    }

    func testLogLineWithoutSessionControlSaysItWasOnlyStored() {
        let line = audioOutputRequestLogLine(requested: "builtin", lastRequested: nil, reported: nil, decision: .apply, hasSessionControl: false, viaCallKit: false)
        XCTAssertEqual(line, "audio output request builtin (last request none, session reports unknown, direct): stored, no session control yet")
    }

    func testAutomaticSpeakerEnforcementGivesUpAfterThreeAttempts() {
        var enforcement = AutomaticSpeakerEnforcement()
        XCTAssertTrue(enforcement.shouldAttempt())
        XCTAssertTrue(enforcement.shouldAttempt())
        XCTAssertTrue(enforcement.shouldAttempt())
        XCTAssertFalse(enforcement.shouldAttempt())
        XCTAssertFalse(enforcement.shouldAttempt())
    }

    func testAutomaticSpeakerEnforcementStartsOverAfterAReset() {
        var enforcement = AutomaticSpeakerEnforcement()
        for _ in 0 ..< 5 {
            _ = enforcement.shouldAttempt()
        }
        enforcement.reset()
        XCTAssertTrue(enforcement.shouldAttempt())
    }
}
