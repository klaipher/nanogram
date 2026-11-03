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
///    expiration, which iOS also kills.
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

    /// - Parameters:
    ///   - writesStayEnabled: whether database writes stay enabled after this task is gone, as the caller decided
    ///     after dropping it. True only while something else keeps the app awake.
    ///   - backgroundTimeRemaining: `UIApplication.backgroundTimeRemaining` now; bounds the wait.
    ///   - end: ends the task (or calls the completion handler).
    public func release(writesStayEnabled: Bool, backgroundTimeRemaining: Double, end: @escaping () -> Void) {
        if writesStayEnabled {
            end()
            return
        }
        let once = EndOnce(end)
        self.schedule(BackgroundTaskRelease.drainTimeout(backgroundTimeRemaining: backgroundTimeRemaining), {
            once.end()
        })
        self.pauseWrites({
            once.end()
        })
    }

    /// How long to wait for the running transaction: 3 s at most, 1 s before the background time runs out when
    /// there is room for that, and never less than 1 s (the wait the app used before, which never produced a
    /// task-timeout exit in MetricKit).
    public static func drainTimeout(backgroundTimeRemaining: Double) -> Double {
        let maximum = 3.0
        let minimum = 1.0
        guard !backgroundTimeRemaining.isNaN else {
            return minimum
        }
        return min(maximum, max(minimum, backgroundTimeRemaining - 1.0))
    }
}

private final class EndOnce {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func end() {
        guard let action = self.action else {
            return
        }
        self.action = nil
        action()
    }
}
