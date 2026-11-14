import Foundation
import TelegramCore
import NotificationsPresentationData

/// Keeps asking the server whether a call the extension rings as a notification is still ringing,
/// and takes the ring down once it is not. Nothing else tells a killed app that the call was
/// declined or answered on another device: the server sends no push for either.
///
/// Only the timing lives here; the probe, the removal, the clock and the timer are passed in.
/// Callbacks may arrive on any thread.
final class IncomingCallRingWatch {
    enum End: String {
        /// The server said the call is over, and the ring was taken down.
        case ended
        /// The ringtone ran its course without an end signal.
        case window
        /// The system took the extension's time back.
        case expired
    }

    typealias Schedule = (_ delay: Double, _ action: @escaping () -> Void) -> Void

    private static let registryLock = NSLock()
    private static var running: [String: IncomingCallRingWatch] = [:]

    /// Whether a watch for `key` (account and call) runs; used so a repeated push starts none.
    static func isWatching(key: String) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return running[key] != nil
    }

    /// Starts a watch unless one runs for the same key. The watch keeps itself alive until it ends.
    @discardableResult
    static func begin(
        key: String,
        interval: Double = Double(IncomingCallNotifications.ringWatchInterval),
        window: Double = Double(IncomingCallNotifications.ringWatchWindow),
        probe: @escaping (@escaping (IncomingCallProbeResult) -> Void) -> Void,
        removeRing: @escaping (@escaping (Int) -> Void) -> Void,
        schedule: @escaping Schedule = { delay, action in DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: action) },
        now: @escaping () -> Double = { CFAbsoluteTimeGetCurrent() },
        log: @escaping (String) -> Void,
        onFinished: @escaping (End) -> Void = { _ in }
    ) -> IncomingCallRingWatch? {
        registryLock.lock()
        if running[key] != nil {
            registryLock.unlock()
            return nil
        }
        let watch = IncomingCallRingWatch(key: key, interval: interval, window: window, probe: probe, removeRing: removeRing, schedule: schedule, now: now, log: log, onFinished: onFinished)
        running[key] = watch
        registryLock.unlock()
        watch.start()
        return watch
    }

    private let key: String
    private let interval: Double
    private let window: Double
    private let probe: (@escaping (IncomingCallProbeResult) -> Void) -> Void
    private let removeRing: (@escaping (Int) -> Void) -> Void
    private let schedule: Schedule
    private let now: () -> Double
    private let log: (String) -> Void
    private let onFinished: (End) -> Void

    private let lock = NSLock()
    private var startedAt: Double = 0.0
    private var probeCount = 0
    private var isFinished = false

    private init(key: String, interval: Double, window: Double, probe: @escaping (@escaping (IncomingCallProbeResult) -> Void) -> Void, removeRing: @escaping (@escaping (Int) -> Void) -> Void, schedule: @escaping Schedule, now: @escaping () -> Double, log: @escaping (String) -> Void, onFinished: @escaping (End) -> Void) {
        self.key = key
        self.interval = interval
        self.window = window
        self.probe = probe
        self.removeRing = removeRing
        self.schedule = schedule
        self.now = now
        self.log = log
        self.onFinished = onFinished
    }

    private func start() {
        self.startedAt = self.now()
        self.scheduleNext()
    }

    /// The system's expiry callback: the watch ends where it stands.
    func expire() {
        self.finish(.expired)
    }

    private func elapsed() -> Double {
        return self.now() - self.startedAt
    }

    private func scheduleNext() {
        self.schedule(self.interval) { [self] in
            self.tick()
        }
    }

    private func tick() {
        self.lock.lock()
        let finished = self.isFinished
        self.lock.unlock()
        if finished {
            return
        }
        if self.elapsed() >= self.window {
            self.finish(.window)
            return
        }
        self.probe { [self] result in
            self.lock.lock()
            if self.isFinished {
                self.lock.unlock()
                return
            }
            self.probeCount += 1
            let count = self.probeCount
            self.lock.unlock()
            self.log("probe #\(count) +\(String(format: "%.2f", self.elapsed()))s \(IncomingCallRingWatch.describe(result))")
            if case .ended = result {
                self.removeRing { [self] removed in
                    self.log("ring removed by watch +\(String(format: "%.2f", self.elapsed()))s n=\(removed)")
                    self.finish(.ended)
                }
            } else if self.elapsed() >= self.window {
                self.finish(.window)
            } else {
                self.scheduleNext()
            }
        }
    }

    private func finish(_ end: End) {
        self.lock.lock()
        if self.isFinished {
            self.lock.unlock()
            return
        }
        self.isFinished = true
        self.lock.unlock()
        IncomingCallRingWatch.registryLock.lock()
        IncomingCallRingWatch.running[self.key] = nil
        IncomingCallRingWatch.registryLock.unlock()
        self.log("watch end \(end.rawValue) +\(String(format: "%.2f", self.elapsed()))s")
        self.onFinished(end)
    }

    static func describe(_ result: IncomingCallProbeResult) -> String {
        switch result {
        case .ringing:
            return "ringing"
        case let .ended(name):
            return "ended(\(name))"
        case .unknown:
            return "unknown"
        }
    }
}
