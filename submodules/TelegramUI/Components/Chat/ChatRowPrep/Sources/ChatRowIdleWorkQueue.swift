import Foundation
import CoreFoundation

/// Work that must not run inside a scroll frame (removing and releasing the views of rows that left the band). It runs
/// when the main run loop is about to wait, a little at a time, so a frame is never delayed by more than `budget`.
///
/// Main thread only. The run-loop observer exists only while work is queued.
public final class ChatRowIdleWorkQueue {
    private var pending: [() -> Void] = []
    private var observer: CFRunLoopObserver?
    private let budget: TimeInterval
    private let clock: () -> TimeInterval

    public init(budget: TimeInterval = 0.002, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.budget = budget
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

    public func enqueue(_ work: @escaping () -> Void) {
        self.pending.append(work)
        self.installObserverIfNeeded()
    }

    /// Runs queued work in order until `budget` is spent; at least one item runs. Returns whether work is left.
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
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            let _ = self?.runPending()
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            self.observer = observer
        }
    }

    private func removeObserver() {
        if let observer = self.observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
    }
}
