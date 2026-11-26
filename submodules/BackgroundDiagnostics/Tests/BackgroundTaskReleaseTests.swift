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
    /// kill): the task ends at the drain deadline, 2 s before the background time runs out.
    func testEndsAtTheDeadlineWhenTheTransactionDoesNotFinish() {
        let release = self.makeRelease()
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, end: { self.events.append("end") })
        XCTAssertEqual(self.scheduled.map(\.delay), [8.0])
        self.scheduled.forEach { $0.action() }
        XCTAssertEqual(self.events, ["pause", "end"])
    }

    /// 24 Nov 2026, build 202611232311: the 20 s "explicit-extension" timer fired with ~10 s left, a background
    /// transaction (chat-list replay reading peer data from disk) ran for more than 4 s, the 3 s cap ended the
    /// task while it still held the lock, and iOS killed the suspended app (MetricKit `fileLock`). The task is
    /// now held for as long as the background time allows, minus the margin.
    func testWaitsForASlowTransactionUntilShortlyBeforeExpiration() {
        let release = self.makeRelease()
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, end: { self.events.append("end") })
        XCTAssertGreaterThan(self.scheduled.map(\.delay).first ?? 0.0, 4.3)
        XCTAssertEqual(self.events, ["pause"])
        self.pauseCallbacks.forEach { $0() }
        XCTAssertEqual(self.events, ["pause", "end"])
    }

    /// A drain that times out is reported (it means the task ends while a transaction may still hold the lock), and
    /// before the task ends: ending it flushes the logs, so the line is in them if iOS kills the suspended app.
    func testReportsATimeoutBeforeEndingTheTask() {
        let release = self.makeRelease()
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, timedOut: { waited in
            self.events.append("timeout \(waited)")
        }, end: { self.events.append("end") })
        self.scheduled.forEach { $0.action() }
        XCTAssertEqual(self.events, ["pause", "timeout 8.0", "end"])
        self.pauseCallbacks.forEach { $0() }
        XCTAssertEqual(self.events, ["pause", "timeout 8.0", "end"])
    }

    /// Writes paused in time: the deadline that fires later is not a timeout.
    func testDoesNotReportATimeoutWhenWritesPausedInTime() {
        let release = self.makeRelease()
        var timeouts = 0
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, timedOut: { _ in
            timeouts += 1
        }, end: { self.events.append("end") })
        self.pauseCallbacks.forEach { $0() }
        self.scheduled.forEach { $0.action() }
        XCTAssertEqual(timeouts, 0)
        XCTAssertEqual(self.events, ["pause", "end"])
    }

    /// A push's or background fetch's completion has its own deadline, not `backgroundTimeRemaining` (the push timer
    /// fires 5 s before it): it keeps the 3 s cap.
    func testCompletionKeepsTheShortCap() {
        let release = self.makeRelease()
        release.release(writesStayEnabled: false, backgroundTimeRemaining: 10.0, maximumWait: BackgroundTaskRelease.completionMaximumWait, end: { self.events.append("end") })
        XCTAssertEqual(self.scheduled.map(\.delay), [3.0])
    }

    /// The system's expiration comes while the drain still waits for the running transaction: the task's expiration
    /// handler ends it at once (a task held past its expiration is a task-timeout kill), and neither the paused
    /// writes nor the deadline end it a second time.
    func testExpirationDuringDrainEndsOnce() {
        let release = self.makeRelease()
        var ends = 0
        var timeouts = 0
        let drain = release.release(writesStayEnabled: false, backgroundTimeRemaining: 30.0, timedOut: { _ in
            timeouts += 1
        }, end: { ends += 1 })
        XCTAssertTrue(drain.isPending)
        drain.endNow()
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(drain.isPending)
        self.pauseCallbacks.forEach { $0() }
        self.scheduled.forEach { $0.action() }
        drain.endNow()
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(timeouts, 0, "an expiration is not a drain timeout")
    }

    /// An expiration that comes after the drain ended the task does nothing.
    func testExpirationAfterTheDrainEndedDoesNothing() {
        let release = self.makeRelease()
        var ends = 0
        let drain = release.release(writesStayEnabled: false, backgroundTimeRemaining: 30.0, end: { ends += 1 })
        self.pauseCallbacks.forEach { $0() }
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(drain.isPending)
        drain.endNow()
        XCTAssertEqual(ends, 1)
    }

    /// Writes stay enabled: the task ended at once, and the drain it returns is already over.
    func testDrainIsOverWhenWritesStayEnabled() {
        let release = self.makeRelease()
        var ends = 0
        let drain = release.release(writesStayEnabled: true, backgroundTimeRemaining: 30.0, end: { ends += 1 })
        XCTAssertFalse(drain.isPending)
        drain.endNow()
        XCTAssertEqual(ends, 1)
    }

    /// A task whose expiration ends it ("audio-end-drain", while `backgroundTimeRemaining` still reads DBL_MAX as the
    /// audio assertion is let go) can wait longer than the short no-deadline cap.
    func testNoDeadlineWaitCanBeLongerForATaskBoundByItsExpiration() {
        let release = self.makeRelease()
        release.release(writesStayEnabled: false, backgroundTimeRemaining: Double.greatestFiniteMagnitude, noDeadlineWait: BackgroundTaskRelease.taskMaximumWait, end: {})
        XCTAssertEqual(self.scheduled.map(\.delay), [25.0])
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: Double.greatestFiniteMagnitude, maximum: BackgroundTaskRelease.completionMaximumWait, noDeadlineWait: BackgroundTaskRelease.taskMaximumWait), 3.0)
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

    /// The wait for the running transaction: until 2 s before the background time runs out (the "explicit-extension"
    /// expiration handler does nothing once its timer fired, so the task must end before that), at least 1 s, at
    /// most 25 s. A value that is no deadline (DBL_MAX in the foreground or with audio, infinity) waits 3 s.
    func testDrainTimeout() {
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 30.0), 25.0)
        // The 20 s "explicit-extension" timer, with ~10 s left.
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 10.0), 8.0)
        // The "background-wakeup" timer fires 5 s before the end.
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 5.0), 3.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 3.0), 1.0)
        // The system's expiration handler, with almost nothing left: the 1 s wait that never produced a
        // task-timeout exit in MetricKit.
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 0.5), 1.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 0.0), 1.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: -1.0), 1.0)
        // A long background time (a BGContinuedProcessingTask) is still capped.
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 600.0), 25.0)
        // In the foreground, or while audio plays, `backgroundTimeRemaining` is DBL_MAX: not a deadline.
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: Double.greatestFiniteMagnitude), 3.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: Double.infinity), 3.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: Double.nan), 1.0)
    }

    /// Completions: at most 3 s, still 2 s before the background time runs out when there is room for that.
    func testCompletionDrainTimeout() {
        let maximum = BackgroundTaskRelease.completionMaximumWait
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 30.0, maximum: maximum), 3.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 4.0, maximum: maximum), 2.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: 0.5, maximum: maximum), 1.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: Double.greatestFiniteMagnitude, maximum: maximum), 3.0)
        XCTAssertEqual(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: Double.nan, maximum: maximum), 1.0)
    }
}
