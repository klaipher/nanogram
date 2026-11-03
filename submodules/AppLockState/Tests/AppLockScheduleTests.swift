import XCTest
@testable import AppLockState

/// What a widget or extension shows depends on whether the passcode lock applies now, and a widget timeline drawn
/// while the app is unlocked must also know when the auto-lock will apply, to hide its content at that moment.
final class AppLockScheduleTests: XCTestCase {
    private let now = MonotonicTimestamp(bootTimestamp: 1000, uptime: 5000)

    func testNoPasscodeLockNeverLocks() {
        XCTAssertEqual(appLockSchedule(state: nil, now: self.now), .unlocked)
        XCTAssertEqual(appLockSchedule(state: LockState(), now: self.now), .unlocked)
    }

    func testManualLockIsLocked() {
        XCTAssertEqual(appLockSchedule(state: LockState(isManuallyLocked: true, autolockTimeout: 600), now: self.now), .locked)
    }

    func testAutolockLocksAtTheDeadline() {
        let active = MonotonicTimestamp(bootTimestamp: 1000, uptime: 4900)
        XCTAssertEqual(appLockSchedule(state: LockState(autolockTimeout: 600, applicationActivityTimestamp: active), now: self.now), .locksIn(500))
        XCTAssertEqual(appLockSchedule(state: LockState(autolockTimeout: 100, applicationActivityTimestamp: active), now: self.now), .locked)
        XCTAssertEqual(appLockSchedule(state: LockState(autolockTimeout: 0, applicationActivityTimestamp: active), now: self.now), .locked)
    }

    func testAutolockAfterARebootOrWithoutActivityIsLocked() {
        let beforeReboot = MonotonicTimestamp(bootTimestamp: 999, uptime: 4999)
        XCTAssertEqual(appLockSchedule(state: LockState(autolockTimeout: 600, applicationActivityTimestamp: beforeReboot), now: self.now), .locked)
        XCTAssertEqual(appLockSchedule(state: LockState(autolockTimeout: 600), now: self.now), .locked)
    }
}
