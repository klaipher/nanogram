import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore

public enum PeerPresenceStatusRefreshMode {
    // Refresh whenever "online" / "last seen ..." text can change.
    case statusText
    // Refresh only when the online state flips (chat list online dot).
    case onlineState
}

// Seconds until the presence-derived UI can change, relative to `timestamp` (unix time with fraction).
// Returns .infinity when nothing will change.
public func peerPresenceStatusRefreshTimeout(_ presence: EnginePeer.Presence, relativeTo timestamp: Double, isOnline: Bool?, mode: PeerPresenceStatusRefreshMode) -> Double {
    // Presence is compared against whole seconds, so a change at second `s` is visible from `s` on.
    // Aim at that boundary from the precise time: aiming at `s` from a truncated clock fired inside
    // the same second and re-armed with zero timeouts until it passed.
    func until(_ second: Int32) -> Double {
        return max(0.05, Double(second) - timestamp)
    }
    let now = Int32(timestamp)
    switch presence.status {
    case let .present(statusTimestamp):
        if statusTimestamp >= now {
            // Online through `statusTimestamp`, offline from the next second.
            return until(statusTimestamp + 1)
        } else {
            if let isOnline = isOnline, isOnline {
                return 1.0
            }
            if case .onlineState = mode {
                return Double.infinity
            }
            let difference = now - statusTimestamp
            if difference < 31 {
                return until(statusTimestamp + 31)
            } else if difference < 60 * 60 {
                // "N minutes ago" changes at every whole minute.
                return until(statusTimestamp + (difference / 60 + 1) * 60)
            } else {
                return Double.infinity
            }
        }
    case .recently:
        let activeUntil = presence.lastActivity + 30
        if activeUntil >= now {
            return until(activeUntil + 1)
        } else {
            return Double.infinity
        }
    case .longTimeAgo, .lastWeek, .lastMonth:
        return Double.infinity
    }
}

// Clock, timers and app state used by PeerPresenceStatusManager. Replaceable in tests.
public protocol PeerPresenceStatusManagerEnvironment: AnyObject {
    var currentTimestamp: Double { get }
    var isApplicationInBackground: Bool { get }
    func scheduleTimer(timeout: Double, _ f: @escaping () -> Void) -> Disposable
    func addApplicationStateListener(_ f: @escaping () -> Void) -> Disposable
}

private final class DefaultPeerPresenceStatusManagerEnvironment: PeerPresenceStatusManagerEnvironment {
    static let shared = DefaultPeerPresenceStatusManagerEnvironment()

    private let lock = NSLock()
    private var listeners = Bag<() -> Void>()
    private var isInBackground = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: OperationQueue.main, using: { [weak self] _ in
            self?.setInBackground(true)
        }))
        self.observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: OperationQueue.main, using: { [weak self] _ in
            self?.setInBackground(false)
        }))
    }

    private func setInBackground(_ value: Bool) {
        self.lock.lock()
        let changed = self.isInBackground != value
        self.isInBackground = value
        let listeners = changed ? self.listeners.copyItems() : []
        self.lock.unlock()
        for f in listeners {
            f()
        }
    }

    var currentTimestamp: Double {
        return CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
    }

    var isApplicationInBackground: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.isInBackground
    }

    func scheduleTimer(timeout: Double, _ f: @escaping () -> Void) -> Disposable {
        let timer = SwiftSignalKit.Timer(timeout: timeout, repeat: false, completion: f, queue: Queue.mainQueue())
        timer.start()
        return ActionDisposable {
            timer.invalidate()
        }
    }

    func addApplicationStateListener(_ f: @escaping () -> Void) -> Disposable {
        self.lock.lock()
        let index = self.listeners.add(f)
        self.lock.unlock()
        return ActionDisposable { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            self.listeners.remove(index)
            self.lock.unlock()
        }
    }
}

// Calls `update` (on the main queue) when the presence-derived UI should be refreshed.
// While the app is in the background no timers run; a refresh that became due is
// delivered once when the app returns to the foreground.
public final class PeerPresenceStatusManager {
    private let update: () -> Void
    private let mode: PeerPresenceStatusRefreshMode
    private let environment: PeerPresenceStatusManagerEnvironment

    private var deadline: Double?
    private var timer: Disposable?
    private var applicationStateDisposable: Disposable?

    public convenience init(update: @escaping () -> Void) {
        self.init(mode: .statusText, update: update)
    }

    public convenience init(mode: PeerPresenceStatusRefreshMode, update: @escaping () -> Void) {
        self.init(mode: mode, environment: DefaultPeerPresenceStatusManagerEnvironment.shared, update: update)
    }

    public init(mode: PeerPresenceStatusRefreshMode, environment: PeerPresenceStatusManagerEnvironment, update: @escaping () -> Void) {
        self.mode = mode
        self.environment = environment
        self.update = update

        self.applicationStateDisposable = environment.addApplicationStateListener({ [weak self] in
            self?.applicationStateUpdated()
        })
    }

    deinit {
        self.timer?.dispose()
        self.applicationStateDisposable?.dispose()
    }

    public func reset(presence: EnginePeer.Presence, isOnline: Bool? = nil) {
        self.timer?.dispose()
        self.timer = nil
        self.deadline = nil

        let timestamp = self.environment.currentTimestamp
        let timeout = peerPresenceStatusRefreshTimeout(presence, relativeTo: timestamp, isOnline: isOnline, mode: self.mode)
        if timeout.isFinite {
            self.deadline = timestamp + timeout
            self.scheduleTimerIfNeeded()
        }
    }

    private func scheduleTimerIfNeeded() {
        guard self.timer == nil, let deadline = self.deadline, !self.environment.isApplicationInBackground else {
            return
        }
        let timeout = max(0.0, deadline - self.environment.currentTimestamp)
        self.timer = self.environment.scheduleTimer(timeout: timeout, { [weak self] in
            self?.timerFired()
        })
    }

    private func timerFired() {
        self.timer?.dispose()
        self.timer = nil
        if self.environment.isApplicationInBackground {
            return
        }
        self.deadline = nil
        self.update()
    }

    private func applicationStateUpdated() {
        if self.environment.isApplicationInBackground {
            self.timer?.dispose()
            self.timer = nil
        } else if let deadline = self.deadline, self.timer == nil {
            if self.environment.currentTimestamp >= deadline {
                self.deadline = nil
                self.update()
            } else {
                self.scheduleTimerIfNeeded()
            }
        }
    }
}
