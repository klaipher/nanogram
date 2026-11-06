import Foundation

/// Ends one notification request. iOS suspends the extension soon after `contentHandler` runs,
/// and a process suspended while it holds a SQLite lock in the shared container is killed
/// (0xdead10cc) or blocks the app's next write for the busy timeout. So the request:
/// - holds a process activity from its start until its databases stopped taking transactions;
/// - asks the databases to pause, and delivers the content once they did, or after
///   `deliverTimeout` so a stuck transaction cannot hold the notification back;
/// - ends the activity once delivered and paused, or after `activityTimeout` at the latest.
/// Callbacks may arrive on any queue.
final class ExtensionRequestCompletion {
    typealias Schedule = (_ delay: Double, _ action: @escaping () -> Void) -> Void

    private let lock = NSLock()
    private var endActivity: (() -> Void)?
    private var isFinishing = false
    private var pendingDeliver: (() -> Void)?
    private var isDelivered = false
    private var isPaused = false

    init(beginActivity: () -> () -> Void) {
        self.endActivity = beginActivity()
    }

    deinit {
        self.endActivity?()
    }

    /// Only the first call counts; later ones are ignored.
    func finish(pauseDatabases: (@escaping () -> Void) -> Void, deliverTimeout: Double, activityTimeout: Double, schedule: Schedule, deliver: @escaping () -> Void) {
        self.lock.lock()
        if self.isFinishing {
            self.lock.unlock()
            return
        }
        self.isFinishing = true
        self.pendingDeliver = deliver
        self.lock.unlock()

        // The timers hold the request, so it outlives its owner until the activity timeout.
        if deliverTimeout <= 0.0 {
            self.deliverNow()
        } else {
            schedule(deliverTimeout, {
                self.deliverNow()
            })
        }
        schedule(activityTimeout, {
            self.deliverNow()
            self.endActivityNow()
        })
        pauseDatabases({ [weak self] in
            self?.databasesPaused()
        })
    }

    /// The system is taking control back: deliver what is pending now.
    func expire() {
        self.deliverNow()
    }

    private func databasesPaused() {
        self.lock.lock()
        self.isPaused = true
        self.lock.unlock()
        self.deliverNow()
        self.endActivityIfDone()
    }

    private func deliverNow() {
        self.lock.lock()
        let deliver = self.pendingDeliver
        self.pendingDeliver = nil
        if deliver != nil {
            self.isDelivered = true
        }
        self.lock.unlock()
        deliver?()
        self.endActivityIfDone()
    }

    private func endActivityIfDone() {
        self.lock.lock()
        let done = self.isDelivered && self.isPaused
        self.lock.unlock()
        if done {
            self.endActivityNow()
        }
    }

    private func endActivityNow() {
        self.lock.lock()
        let endActivity = self.endActivity
        self.endActivity = nil
        self.lock.unlock()
        endActivity?()
    }
}

/// A `ProcessInfo.performExpiringActivity` held until `end()`: the system keeps the process
/// running while the block runs, and calls it again with `expired == true` when it will suspend
/// anyway. Apple's 0xdead10cc guidance for app extensions is a process activity.
final class ExpiringProcessActivity {
    typealias Perform = (_ block: @escaping (_ expired: Bool) -> Void) -> Void

    private let semaphore = DispatchSemaphore(value: 0)
    private let flushLogs: () -> Void

    /// `flushLogs` runs when the activity ends (`end()` or release), before the process may be suspended, so the
    /// lines logged up to then (the pause and delivery of the request) are written.
    init(reason: String, flushLogs: @escaping () -> Void = {}, perform: Perform? = nil) {
        self.flushLogs = flushLogs
        let semaphore = self.semaphore
        let block: (Bool) -> Void = { expired in
            if expired {
                // Stop the waiting call, if any.
                semaphore.signal()
            } else {
                // Runs on a background queue: wait until the request is done.
                semaphore.wait()
            }
        }
        if let perform {
            perform(block)
        } else {
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: block)
        }
    }

    deinit {
        self.flushLogs()
        self.semaphore.signal()
    }

    func end() {
        self.flushLogs()
        self.semaphore.signal()
    }
}
