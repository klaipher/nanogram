import XCTest
@testable import BackgroundDiagnostics

/// "background-wakeup" is begun again on every `checkTasks` that may extend: what happens to the task it replaces.
final class BackgroundTaskRotationTests: XCTestCase {
    /// The new task was granted and keeps the app awake: the old one ends at once, and the new one is held.
    func testGrantedReplacementEndsTheOldTaskAtOnce() {
        XCTAssertEqual(BackgroundTaskRotation<Int>.rotate(replaced: 1, granted: 2), BackgroundTaskRotation(held: 2, endNow: 1, release: nil))
    }

    /// iOS refused the new task: the old one may be all that keeps the app awake. It is not dropped (it would be held
    /// past its expiration, a task-timeout kill) and not ended at once (a running write would hold the lock while
    /// the app suspends, 0xdead10cc): it goes through the release. Nothing is held, so writes are not kept enabled.
    func testRefusedReplacementReleasesTheOldTask() {
        XCTAssertEqual(BackgroundTaskRotation<Int>.rotate(replaced: 1, granted: nil), BackgroundTaskRotation(held: nil, endNow: nil, release: 1))
    }

    func testFirstTaskGranted() {
        XCTAssertEqual(BackgroundTaskRotation<Int>.rotate(replaced: nil, granted: 2), BackgroundTaskRotation(held: 2, endNow: nil, release: nil))
    }

    func testFirstTaskRefused() {
        XCTAssertEqual(BackgroundTaskRotation<Int>.rotate(replaced: nil, granted: nil), BackgroundTaskRotation(held: nil, endNow: nil, release: nil))
    }
}
