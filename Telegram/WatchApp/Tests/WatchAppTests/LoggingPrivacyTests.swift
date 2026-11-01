import XCTest
@testable import tgwatch_Watch_App

/// Auth-state transitions are logged publicly (`.notice`, persisted by the unified log), so
/// the logged form must not carry the QR login token, the phone number or the password hint.
final class LoggingPrivacyTests: XCTestCase {
    func testAuthStateLogDescriptionDropsQrLoginToken() {
        let state = AuthState.waitOtherDeviceConfirmation(link: "tg://login?token=SECRETTOKEN")
        XCTAssertEqual(state.logDescription, "waitOtherDeviceConfirmation")
    }

    func testAuthStateLogDescriptionDropsPhoneNumber() {
        let state = AuthState.waitCode(info: CodeInfo(phoneNumber: "+15550001234", codeLength: 5, typeDescription: "SMS"))
        XCTAssertEqual(state.logDescription, "waitCode")
    }

    func testAuthStateLogDescriptionDropsPasswordHint() {
        let state = AuthState.waitPassword(info: PasswordInfo(hint: "my dog's name", hasRecoveryEmail: true))
        XCTAssertEqual(state.logDescription, "waitPassword")
    }

    func testAuthStateLogDescriptionDropsFailureText() {
        XCTAssertEqual(AuthState.failed("anything").logDescription, "failed")
    }

    func testAuthStateLogDescriptionNamesPlainStates() {
        let states: [AuthState] = [.starting, .waitTdlibParameters, .waitPhoneNumber, .ready, .loggingOut, .closed]
        XCTAssertEqual(states.map(\.logDescription),
                       ["starting", "waitTdlibParameters", "waitPhoneNumber", "ready", "loggingOut", "closed"])
    }
}

/// TDLib logs to stderr at verbosity 5 until told otherwise; release builds keep it to fatal
/// errors and ignore the environment, debug builds default to errors and accept an override.
final class TDLibLogPolicyTests: XCTestCase {
    func testReleaseIsFatalOnlyAndIgnoresEnvironment() {
        XCTAssertEqual(TDLibLogPolicy.verbosity(environment: [:], isDebugBuild: false), 0)
        XCTAssertEqual(TDLibLogPolicy.verbosity(environment: ["TGWATCH_TDLIB_VERBOSITY": "5"], isDebugBuild: false), 0)
    }

    func testDebugDefaultsToErrors() {
        XCTAssertEqual(TDLibLogPolicy.verbosity(environment: [:], isDebugBuild: true), 1)
    }

    func testDebugAcceptsOverride() {
        XCTAssertEqual(TDLibLogPolicy.verbosity(environment: ["TGWATCH_TDLIB_VERBOSITY": "4"], isDebugBuild: true), 4)
    }

    func testDebugRejectsInvalidOverride() {
        XCTAssertEqual(TDLibLogPolicy.verbosity(environment: ["TGWATCH_TDLIB_VERBOSITY": "loud"], isDebugBuild: true), 1)
        XCTAssertEqual(TDLibLogPolicy.verbosity(environment: ["TGWATCH_TDLIB_VERBOSITY": "-3"], isDebugBuild: true), 1)
    }
}
