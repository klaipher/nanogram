import XCTest
import TelegramAudio

final class ManagedAudioSessionDeactivationRetryGateTests: XCTestCase {
    func testRetryRunsWhenNothingHappenedInTheMeantime() {
        var gate = ManagedAudioSessionDeactivationRetryGate()
        let token = gate.advance()
        XCTAssertTrue(gate.allowsRetry(token: token, sessionIsIdle: true))
    }

    func testRetryIsDroppedWhenALaterRequestActivatedTheSession() {
        var gate = ManagedAudioSessionDeactivationRetryGate()
        let token = gate.advance()
        gate.advance()
        XCTAssertFalse(gate.allowsRetry(token: token, sessionIsIdle: false))
    }

    func testRetryIsDroppedWhenTheSessionWasUsedAndWentIdleAgain() {
        var gate = ManagedAudioSessionDeactivationRetryGate()
        let token = gate.advance()
        gate.advance()
        XCTAssertFalse(gate.allowsRetry(token: token, sessionIsIdle: true))
    }

    func testRetryIsDroppedWhileTheSessionHoldsAType() {
        var gate = ManagedAudioSessionDeactivationRetryGate()
        let token = gate.advance()
        XCTAssertFalse(gate.allowsRetry(token: token, sessionIsIdle: false))
    }

    func testNewestTokenWinsOverAnOlderRetry() {
        var gate = ManagedAudioSessionDeactivationRetryGate()
        let first = gate.advance()
        let second = gate.advance()
        XCTAssertFalse(gate.allowsRetry(token: first, sessionIsIdle: true))
        XCTAssertTrue(gate.allowsRetry(token: second, sessionIsIdle: true))
    }
}
