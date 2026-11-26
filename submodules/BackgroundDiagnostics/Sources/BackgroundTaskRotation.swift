/// What happens when a held background task is replaced by a new one ("background-wakeup" is begun again on every
/// `SharedWakeupManager.checkTasks` that may extend the app's background time).
///
/// iOS can refuse the new task (`beginBackgroundTask` returns `.invalid`). Then nothing replaced the old task, and the
/// old one may be the only thing keeping the app awake: it goes through `BackgroundTaskRelease` (writes pause first,
/// 0xdead10cc), and no task is held, so writes are not kept enabled for one. Dropping the old task without ending it
/// would hold it past its expiration (a task-timeout kill) and keep writes enabled with nothing keeping the app awake.
public struct BackgroundTaskRotation<Identifier: Equatable>: Equatable {
    /// The task held after the rotation; nil when the new one was not granted.
    public let held: Identifier?
    /// The replaced task, to end at once: the new task keeps the app awake.
    public let endNow: Identifier?
    /// The replaced task, to end through `BackgroundTaskRelease` after writes were recomputed: nothing replaced it.
    public let release: Identifier?

    public init(held: Identifier?, endNow: Identifier?, release: Identifier?) {
        self.held = held
        self.endNow = endNow
        self.release = release
    }

    /// - Parameters:
    ///   - replaced: the task being replaced, if one was held.
    ///   - granted: the new task, nil when iOS did not grant one (`.invalid` maps to nil).
    public static func rotate(replaced: Identifier?, granted: Identifier?) -> BackgroundTaskRotation<Identifier> {
        if let granted {
            return BackgroundTaskRotation(held: granted, endNow: replaced, release: nil)
        } else {
            return BackgroundTaskRotation(held: nil, endNow: nil, release: replaced)
        }
    }
}
