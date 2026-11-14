import XCTest
import SwiftSignalKit
@testable import TelegramCore

final class CallRingTimeoutTests: XCTestCase {
    private final class FakeTimer {
        var delays: [Double] = []
        var actions: [() -> Void] = []
        var cancelled = 0

        var factory: CallRingTimerFactory {
            return { delay, _, fire in
                self.delays.append(delay)
                self.actions.append(fire)
                return ActionDisposable {
                    self.cancelled += 1
                }
            }
        }
    }

    func testDelayIsServerTimeoutPlusGraceFromLocalReceipt() {
        XCTAssertEqual(CallRingTimeout.delay(serverTimeoutMs: 90_000), 100.0)
        XCTAssertEqual(CallRingTimeout.delay(serverTimeoutMs: 45_000), 55.0)
        XCTAssertEqual(CallRingTimeout.delay(serverTimeoutMs: nil), 100.0)
    }

    func testServerTimeoutIsBounded() {
        XCTAssertEqual(CallRingTimeout.validatedServerTimeoutMs(60_000), 60_000)
        XCTAssertNil(CallRingTimeout.validatedServerTimeoutMs(0))
        XCTAssertNil(CallRingTimeout.validatedServerTimeoutMs(999))
        XCTAssertNil(CallRingTimeout.validatedServerTimeoutMs(600_001))
        XCTAssertNil(CallRingTimeout.validatedServerTimeoutMs(nil))
    }

    func testExpiresWhileStillRinging() {
        let timer = FakeTimer()
        var expired = 0
        _ = CallRingTimeout.arm(delay: 100, queue: Queue.mainQueue(), makeTimer: timer.factory, isRinging: { true }, expire: { expired += 1 })
        XCTAssertEqual(timer.delays, [100])
        XCTAssertEqual(expired, 0)
        timer.actions[0]()
        XCTAssertEqual(expired, 1)
    }

    func testDoesNothingOnceTheCallLeftRinging() {
        let timer = FakeTimer()
        var ringing = true
        var expired = 0
        _ = CallRingTimeout.arm(delay: 100, queue: Queue.mainQueue(), makeTimer: timer.factory, isRinging: { ringing }, expire: { expired += 1 })
        ringing = false
        timer.actions[0]()
        XCTAssertEqual(expired, 0)
    }

    func testDisposingTheArmedTimerCancelsIt() {
        let timer = FakeTimer()
        let disposable = CallRingTimeout.arm(delay: 100, queue: Queue.mainQueue(), makeTimer: timer.factory, isRinging: { true }, expire: {})
        disposable.dispose()
        XCTAssertEqual(timer.cancelled, 1)
    }
}
