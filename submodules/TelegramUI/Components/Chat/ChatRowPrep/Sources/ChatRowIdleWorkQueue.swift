public import Foundation
public import CoreFoundation

/// Work that must not run inside a scroll frame (removing and releasing the views of rows that left the band). It runs
/// when the main run loop is about to wait, a little at a time.
///
/// Two rules keep it out of the frame. The observer runs after the Core Animation commit (UIKit's before-commit handler is
/// near 1999000, the commit at 2000000, its after-commit at 2001000), and the run-loop turn in which work was queued is
/// skipped, so the first item runs on the following idle turn. The budget is checked after each item, and an item is
/// not split, so one item that is slow on its own (a large bubble) can still take longer than `budget`.
///
/// The queue is bounded (`maxPending`): `hasRoom(for:)` tells a caller to do the work itself instead of queueing it.
///
/// Main thread only. The run-loop observer exists only while work is queued.
public final class ChatRowIdleWorkQueue {
    /// Above the Core Animation commit and its after-commit handler.
    public static let observerOrder: CFIndex = CFIndex(Int32.max)
    public static let defaultMaxPending = 16

    private var pending: [() -> Void] = []
    private var observer: CFRunLoopObserver?
    /// Work was queued in the current run-loop turn: its idle pass must not run it.
    private var skipNextIdleTurn = false
    private let budget: TimeInterval
    private let clock: () -> TimeInterval
    public let maxPending: Int

    public init(budget: TimeInterval = 0.002, maxPending: Int = ChatRowIdleWorkQueue.defaultMaxPending, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.budget = budget
        self.maxPending = maxPending
        self.clock = clock
    }

    deinit {
        self.removeObserver()
    }

    public var pendingCount: Int {
        return self.pending.count
    }

    public var isObserving: Bool {
        return self.observer != nil
    }

    /// Whether `count` more items fit under `maxPending`.
    public func hasRoom(for count: Int = 1) -> Bool {
        return self.pending.count + count <= self.maxPending
    }

    /// Queues `work` for an idle turn after this one. Returns false, and does not queue it, when the queue is full: the
    /// caller then does the work itself.
    @discardableResult
    public func enqueue(_ work: @escaping () -> Void) -> Bool {
        guard self.hasRoom() else {
            return false
        }
        self.pending.append(work)
        self.skipNextIdleTurn = true
        self.installObserverIfNeeded()
        return true
    }

    /// What the run-loop observer does at each idle turn: nothing in the turn in which work was queued (and a wake-up
    /// is requested so there is a following turn), otherwise `runPending()`. Returns whether work ran.
    @discardableResult
    func idleTurn() -> Bool {
        if self.skipNextIdleTurn {
            self.skipNextIdleTurn = false
            self.wakeRunLoop()
            return false
        }
        self.runPending()
        return true
    }

    /// Runs queued work in order until `budget` is spent; at least one item runs (the budget is checked between items). Returns whether work is left.
    @discardableResult
    public func runPending() -> Bool {
        let start = self.clock()
        while !self.pending.isEmpty {
            let work = self.pending.removeFirst()
            work()
            if self.clock() - start >= self.budget {
                break
            }
        }
        if self.pending.isEmpty {
            self.removeObserver()
            return false
        }
        return true
    }

    /// Runs everything now (leaving the chat, memory warning).
    public func flush() {
        while !self.pending.isEmpty {
            let work = self.pending.removeFirst()
            work()
        }
        self.removeObserver()
    }

    /// Drops queued work without running it.
    public func cancelAll() {
        self.pending.removeAll()
        self.removeObserver()
    }

    private func installObserverIfNeeded() {
        guard self.observer == nil else {
            return
        }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, ChatRowIdleWorkQueue.observerOrder) { [weak self] _, _ in
            let _ = self?.idleTurn()
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            self.observer = observer
        }
    }

    /// The loop is about to sleep after a skipped turn; make it run one more.
    private func wakeRunLoop() {
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func removeObserver() {
        self.skipNextIdleTurn = false
        if let observer = self.observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
    }
}
