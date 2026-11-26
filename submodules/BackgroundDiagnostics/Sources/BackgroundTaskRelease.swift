/// Ends a background task, or hands a push or background-fetch completion back to iOS, only after database writes
/// have stopped.
///
/// The account databases live in the shared app-group container, and a write transaction holds the SQLite write lock
/// from `BEGIN IMMEDIATE` to `COMMIT`. iOS kills an app that is suspended while it holds a lock on a file in a shared
/// container (RunningBoard 0xdead10cc, MetricKit `fileLock`), and ending the last background task, or calling a
/// push's completion handler, is what lets iOS suspend it. So the order is:
/// 1. the caller updates its state first (drops the task, recomputes whether writes stay enabled);
/// 2. if writes stay enabled, something else keeps the app awake (the foreground, audio, a call, another background
///    task) and the task ends right away;
/// 3. otherwise writes are paused (new transactions queue, the running one commits) and the task ends once that is
///    done, or at `drainTimeout` at the latest, so a transaction that never finishes cannot hold the task past its
///    expiration, which iOS also kills. A background transaction can take several seconds (a 3 s cap ended the task
///    under a running one, 24 Nov 2026), so the wait lasts until shortly before the background time runs out.
///
/// The system's expiration of the task is the real deadline: `release` returns a `Drain`, and the task's expiration
/// handler calls `Drain.endNow()`, which ends the task at once if the drain still waits. The margin in `drainTimeout`
/// is a backstop for an expiration that is not wired.
///
/// Each `release` ends its task exactly once. Not thread-safe: call it, and deliver `pauseWrites`' callback and
/// `schedule`'s actions, on one queue (the main queue in the app).
public final class BackgroundTaskRelease {
    /// Stops new database transactions and calls `paused` once the running ones have committed.
    public typealias PauseWrites = (_ paused: @escaping () -> Void) -> Void
    public typealias Schedule = (_ delay: Double, _ action: @escaping () -> Void) -> Void

    private let pauseWrites: PauseWrites
    private let schedule: Schedule

    public init(pauseWrites: @escaping PauseWrites, schedule: @escaping Schedule) {
        self.pauseWrites = pauseWrites
        self.schedule = schedule
    }

    /// The longest wait before ending a background task: what the margin leaves of the ~30 s iOS grants on entering
    /// the background.
    public static let taskMaximumWait: Double = 25.0
    /// The longest wait before calling a push's or background fetch's completion handler, or completing a BG task:
    /// their deadlines are their own, not `backgroundTimeRemaining` (the push timer fires 5 s before it).
    public static let completionMaximumWait: Double = 3.0
    /// What the wait leaves before the background time runs out, so the drain ends the task before its expiration
    /// even when that expiration is not wired to `Drain.endNow()` (a task held past it is a task-timeout kill).
    public static let expirationMargin: Double = 2.0
    /// The shortest wait: the one the app used before, which never produced a task-timeout exit in MetricKit.
    public static let minimumWait: Double = 1.0
    /// The wait when `backgroundTimeRemaining` is no deadline: DBL_MAX in the foreground or while audio plays.
    public static let noDeadlineWait: Double = 3.0

    /// A release in progress. The released task's expiration handler calls `endNow()`: iOS kills an app that holds a
    /// task past its expiration, so then the task ends at once even though writes have not paused yet.
    public final class Drain {
        private let once: EndOnce?

        fileprivate init(once: EndOnce?) {
            self.once = once
        }

        /// Whether the task has not ended yet (writes have not paused and the deadline has not come).
        public var isPending: Bool {
            return self.once?.isPending ?? false
        }

        /// Ends the task now if the drain still waits; nothing if it already ended.
        public func endNow() {
            self.once?.end()
        }
    }

    /// - Parameters:
    ///   - writesStayEnabled: whether database writes stay enabled after this task is gone, as the caller decided
    ///     after dropping it. True only while something else keeps the app awake.
    ///   - backgroundTimeRemaining: `UIApplication.backgroundTimeRemaining` now; bounds the wait.
    ///   - maximumWait: the cap on the wait: `taskMaximumWait` for a background task, `completionMaximumWait` for a
    ///     completion handler.
    ///   - noDeadlineWait: the wait when `backgroundTimeRemaining` is no deadline (DBL_MAX). Longer than
    ///     `BackgroundTaskRelease.noDeadlineWait` only for a task whose expiration calls `Drain.endNow()`.
    ///   - timedOut: called with the wait, just before `end`, when the deadline ends the task before writes paused
    ///     (a transaction may still hold the lock).
    ///   - end: ends the task (or calls the completion handler).
    /// - Returns: the drain, for the task's expiration handler; already ended when writes stay enabled.
    @discardableResult
    public func release(writesStayEnabled: Bool, backgroundTimeRemaining: Double, maximumWait: Double = BackgroundTaskRelease.taskMaximumWait, noDeadlineWait: Double = BackgroundTaskRelease.noDeadlineWait, timedOut: ((_ waited: Double) -> Void)? = nil, end: @escaping () -> Void) -> Drain {
        if writesStayEnabled {
            end()
            return Drain(once: nil)
        }
        let once = EndOnce(end)
        let timeout = BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: backgroundTimeRemaining, maximum: maximumWait, noDeadlineWait: noDeadlineWait)
        self.schedule(timeout, {
            if once.isPending {
                timedOut?(timeout)
            }
            once.end()
        })
        self.pauseWrites({
            once.end()
        })
        return Drain(once: once)
    }

    /// How long to wait for the running transaction: until `expirationMargin` before the background time runs out,
    /// at least `minimumWait`, at most `maximum`. NaN waits `minimumWait`; a value that is no deadline (DBL_MAX,
    /// infinity) waits `noDeadlineWait` (at most `maximum`).
    public static func drainTimeout(backgroundTimeRemaining: Double, maximum: Double = BackgroundTaskRelease.taskMaximumWait, noDeadlineWait: Double = BackgroundTaskRelease.noDeadlineWait) -> Double {
        guard !backgroundTimeRemaining.isNaN else {
            return BackgroundTaskRelease.minimumWait
        }
        if backgroundTimeRemaining >= 1.0e6 {
            return min(maximum, noDeadlineWait)
        }
        return min(maximum, max(BackgroundTaskRelease.minimumWait, backgroundTimeRemaining - BackgroundTaskRelease.expirationMargin))
    }
}

private final class EndOnce {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    var isPending: Bool {
        return self.action != nil
    }

    func end() {
        guard let action = self.action else {
            return
        }
        self.action = nil
        action()
    }
}
