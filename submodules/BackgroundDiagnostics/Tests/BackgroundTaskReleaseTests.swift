import XCTest
@testable import BackgroundDiagnostics

/// The order that keeps iOS from killing the app with 0xdead10cc: database writes stop (the running
/// transaction commits) before the background task that kept the app awake is ended.
final class BackgroundTaskReleaseTests: XCTestCase {
    private var events: [String] = []
    private var pauseCallbacks: [() -> Void] = []
    private var scheduled: [(delay: Double, action: () -> Void)] = []

    private func makeRelease() -> BackgroundTaskRelease {
        return BackgroundTaskRelease(pauseWrites: { [unowned self] paused in
            self.events.append("pause")
            self.pauseCallbacks.append(paused)
        }, schedule: { [unowned self] delay, action in
            self.scheduled.append((delay, action))
        })
    }

    /// The 20 s "explicit-extension" timer, a push's completion, the "lock" task: nothing else keeps the
    /// app awake, so writes are paused first and the task ends only once the running transaction committed.
    func testPausesWritesBeforeEndingTheLastTask() {
        let release = self.makeRelease()
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, end: { self.events.append("end") })
        XCTAssertEqual(self.events, ["pause"], "the task must not end while a transaction may still hold the lock")
        self.pauseCallbacks.forEach { $0() }
        XCTAssertEqual(self.events, ["pause", "end"])
    }

    /// Another holder (the foreground, audio, a call, another background task) keeps the app awake and
    /// writes enabled: this task can end right away, and pausing writes would stall that holder's work.
    func testEndsAtOnceWhenWritesStayEnabled() {
        let release = self.makeRelease()
        release.release(writesStayEnabled: true, backgroundTimeRemaining: 10.0, end: { self.events.append("end") })
        XCTAssertEqual(self.events, ["end"])
        XCTAssertTrue(self.scheduled.isEmpty)
    }

    /// A transaction that never finishes cannot hold the task past its expiration (that is a task-timeout
    /// kill): the task ends at the drain deadline.
    func testEndsAtTheDeadlineWhenTheTransactionDoesNotFinish() {
        let release = self.makeRelease()
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, end: { self.events.append("end") })
        XCTAssertEqual(self.scheduled.map(\.delay), [3.0])
        self.scheduled.forEach { $0.action() }
        XCTAssertEqual(self.events, ["pause", "end"])
    }

    func testEndsOnceWhenPausedThenDeadline() {
        let release = self.makeRelease()
        var ends = 0
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, end: { ends += 1 })
        self.pauseCallbacks.forEach { $0() }
        self.scheduled.forEach { $0.action() }
        self.pauseCallbacks.forEach { $0() }
        XCTAssertEqual(ends, 1)
    }

    func testEndsOnceWhenDeadlineThenPaused() {
        let release = self.makeRelease()
        var ends = 0
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, end: { ends += 1 })
        self.scheduled.forEach { $0.action() }
        self.pauseCallbacks.forEach { $0() }
        XCTAssertEqual(ends, 1)
    }

    /// Each release ends its own task: two tasks released together both end, each once.
    func testTwoReleasesEndTheirOwnTasks() {
        let release = self.makeRelease()
        var ended: [String] = []
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, end: { ended.append("explicit-extension") })
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, end: { ended.append("push") })
        XCTAssertEqual(ended, [])
        self.pauseCallbacks.forEach { $0() }
        self.scheduled.forEach { $0.action() }
        XCTAssertEqual(ended, ["explicit-extension", "push"])
    }

    /// The wait for the running transaction: up to 3 s, at least 1 s, and always 1 s before the background
    /// time runs out when there is room for that.
    func testDrainTimeout() {
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 30.0), 3.0)
        // The "background-wakeup" timer fires 5 s before the end; the 20 s timer with ~10 s left.
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 5.0), 3.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 3.0), 2.0)
        // The system's expiration handler, with almost nothing left: the 1 s wait that never produced a
        // task-timeout exit in MetricKit.
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 0.5), 1.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 0.0), 1.0)
        // In the foreground `backgroundTimeRemaining` is DBL_MAX.
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: Double.greatestFiniteMagnitude), 3.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: Double.nan), 1.0)
    }
}
