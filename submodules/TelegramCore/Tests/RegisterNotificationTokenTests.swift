import XCTest
@testable import TelegramCore

// account.registerDevice failures used to be swallowed: every error but TOKEN_WAS_INVALIDATED
// counted as registered, with nothing in the log. They still count (a retry loop on a bad token
// would never end) but are logged, without the token.
final class RegisterNotificationTokenTests: XCTestCase {
    func testAnInvalidatedTokenIsNotRegistered() {
        let outcome = notificationTokenRegistrationFailure(errorDescription: "TOKEN_WAS_INVALIDATED", type: .voip, sandbox: false)
        XCTAssertFalse(outcome.registered)
    }

    func testOtherErrorsCountAsRegisteredAndAreLogged() {
        let outcome = notificationTokenRegistrationFailure(errorDescription: "TOKEN_INVALID", type: .aps(encrypt: true), sandbox: true)
        XCTAssertTrue(outcome.registered)
        XCTAssertEqual(outcome.logLine, "registerDevice failed: TOKEN_INVALID (type aps, sandbox true)")
    }

    func testTheLogLineNamesVoip() {
        let outcome = notificationTokenRegistrationFailure(errorDescription: "INTERNAL", type: .voip, sandbox: false)
        XCTAssertEqual(outcome.logLine, "registerDevice failed: INTERNAL (type voip, sandbox false)")
    }
}
