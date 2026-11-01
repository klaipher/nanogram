import Foundation
import XCTest
import SwiftSignalKit
import TelegramCore
import PeerPresenceStatusManager

// Manual clock and timers. Timers fire only from advance(to:).
private final class FakeEnvironment: PeerPresenceStatusManagerEnvironment {
    private struct PendingTimer {
        let id: Int
        let deadline: Double
        let f: () -> Void
    }

    var currentTimestamp: Double
    var isApplicationInBackground: Bool = false {
        didSet {
            if oldValue != self.isApplicationInBackground {
                for f in self.listeners.copyItems() {
                    f()
                }
            }
        }
    }

    private var nextId = 0
    private var timers: [PendingTimer] = []
    private let listeners = Bag<() -> Void>()
    private(set) var scheduledTimerCount = 0

    init(timestamp: Double) {
        self.currentTimestamp = timestamp
    }

    var pendingTimerCount: Int {
        return self.timers.count
    }

    var nextDeadline: Double? {
        return self.timers.map(\.deadline).min()
    }

    func scheduleTimer(timeout: Double, _ f: @escaping () -> Void) -> Disposable {
        self.nextId += 1
        let id = self.nextId
        self.scheduledTimerCount += 1
        self.timers.append(PendingTimer(id: id, deadline: self.currentTimestamp + timeout, f: f))
        return ActionDisposable { [weak self] in
            self?.timers.removeAll(where: { $0.id == id })
        }
    }

    func addApplicationStateListener(_ f: @escaping () -> Void) -> Disposable {
        let index = self.listeners.add(f)
        return ActionDisposable { [weak self] in
            self?.listeners.remove(index)
        }
    }

    // Fires due timers in deadline order. Returns false if `maxFires` was hit (runaway loop).
    @discardableResult
    func advance(to timestamp: Double, maxFires: Int = 10_000) -> Bool {
        var fires = 0
        while let index = self.timers.indices.min(by: { self.timers[$0].deadline < self.timers[$1].deadline }), self.timers[index].deadline <= timestamp {
            let timer = self.timers.remove(at: index)
            self.currentTimestamp = max(self.currentTimestamp, timer.deadline)
            timer.f()
            fires += 1
            if fires >= maxFires {
                return false
            }
        }
        self.currentTimestamp = max(self.currentTimestamp, timestamp)
        return true
    }
}

private func isOnline(_ presence: EnginePeer.Presence, at timestamp: Double) -> Bool {
    if case let .present(until) = presence.status {
        return until >= Int32(timestamp)
    }
    return false
}

// "last seen" label as the presence strings compute it (minutes granularity, hours after one hour).
private func statusLabel(_ presence: EnginePeer.Presence, at timestamp: Double) -> String {
    guard case let .present(until) = presence.status else {
        return "other"
    }
    let now = Int32(timestamp)
    if until >= now {
        return "online"
    }
    let difference = now - until
    if difference < 60 {
        return "just now"
    } else if difference < 60 * 60 {
        return "\(difference / 60) min"
    } else {
        return "hours"
    }
}

final class PeerPresenceStatusManagerTests: XCTestCase {
    // Simulates a chat list row: each refresh costs `layoutCost` seconds and resets the manager.
    private func makeRow(environment: FakeEnvironment, presence: EnginePeer.Presence, mode: PeerPresenceStatusRefreshMode, layoutCost: Double = 0.002) -> (manager: PeerPresenceStatusManager, updates: () -> Int, shownOnline: () -> Bool) {
        var updateCount = 0
        var shownOnline = isOnline(presence, at: environment.currentTimestamp)
        var managerRef: PeerPresenceStatusManager?
        let manager = PeerPresenceStatusManager(mode: mode, environment: environment, update: {
            updateCount += 1
            environment.currentTimestamp += layoutCost
            shownOnline = isOnline(presence, at: environment.currentTimestamp)
            managerRef?.reset(presence: presence, isOnline: shownOnline)
        })
        managerRef = manager
        manager.reset(presence: presence, isOnline: shownOnline)
        return (manager, { updateCount }, { shownOnline })
    }

    // The device trace showed ~0.9 s of back-to-back relayouts when "online until" expired:
    // the timer was re-armed with a zero timeout for the rest of that second.
    // Build 202611011645 crashed at launch: the Telegram service account (777000) is "online" until
    // Int32.max, and `until + 1` overflowed Int32 while laying out its chat list row.
    func testExtremeTimestampsDoNotOverflow() {
        let now = 1_000_000.25
        let forever = EnginePeer.Presence(status: .present(until: Int32.max), lastActivity: 0)
        for mode in [PeerPresenceStatusRefreshMode.statusText, .onlineState] {
            XCTAssertEqual(peerPresenceStatusRefreshTimeout(forever, relativeTo: now, isOnline: true, mode: mode), Double.infinity)
            XCTAssertEqual(peerPresenceStatusRefreshTimeout(forever, relativeTo: now, isOnline: nil, mode: mode), Double.infinity)
        }
        let longAgo = EnginePeer.Presence(status: .present(until: Int32.min), lastActivity: 0)
        XCTAssertEqual(peerPresenceStatusRefreshTimeout(longAgo, relativeTo: now, isOnline: false, mode: .statusText), Double.infinity)
        let recently = EnginePeer.Presence(status: .recently(isHidden: false), lastActivity: Int32.max)
        XCTAssertGreaterThan(peerPresenceStatusRefreshTimeout(recently, relativeTo: now, isOnline: false, mode: .statusText), 0.0)
        let manager = PeerPresenceStatusManager(update: {})
        manager.reset(presence: forever, isOnline: true)
    }

    // Every combination of extreme server values and clocks: never traps, never NaN, never a busy timer.
    func testTimeoutIsSaneForAnyInput() {
        let seconds: [Int32] = [Int32.min, Int32.min + 1, -31, -1, 0, 1, 30, 31, 3_600, 1_000_000_000, Int32.max - 31, Int32.max - 30, Int32.max - 1, Int32.max]
        var statuses: [EnginePeer.Presence.Status] = [.recently(isHidden: false), .recently(isHidden: true), .lastWeek(isHidden: false), .lastMonth(isHidden: false), .longTimeAgo]
        statuses.append(contentsOf: seconds.map { .present(until: $0) })
        var clocks: [Double] = [0.0, -1.0, 0.5, 1_000_000_000.25, Double(Int32.max), Double(Int32.max) + 0.5, Double(Int32.min), Double(Int32.min) - 1.0, 1e15, -1e15, 1e18, -1e18, 9.3e18, -9.3e18, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan]
        clocks.append(contentsOf: seconds.map { Double($0) + 0.999 })
        for status in statuses {
            for lastActivity in seconds {
                let presence = EnginePeer.Presence(status: status, lastActivity: lastActivity)
                for clock in clocks {
                    for isOnline: Bool? in [nil, true, false] {
                        for mode in [PeerPresenceStatusRefreshMode.statusText, .onlineState] {
                            let timeout = peerPresenceStatusRefreshTimeout(presence, relativeTo: clock, isOnline: isOnline, mode: mode)
                            XCTAssertFalse(timeout.isNaN, "\(status) \(lastActivity) \(clock)")
                            XCTAssertGreaterThanOrEqual(timeout, 0.05, "\(status) \(lastActivity) \(clock)")
                        }
                    }
                }
            }
        }
    }

    // A clock that is not a real date schedules nothing.
    func testNonFiniteClockSchedulesNothing() {
        let presence = EnginePeer.Presence(status: .present(until: 1_000), lastActivity: 0)
        for clock in [Double.nan, .infinity, -.infinity] {
            let environment = FakeEnvironment(timestamp: clock)
            let manager = PeerPresenceStatusManager(mode: .statusText, environment: environment, update: {})
            manager.reset(presence: presence, isOnline: true)
            XCTAssertEqual(environment.pendingTimerCount, 0)
        }
    }

    func testOnlineExpiryRefreshesOnceWithoutSpinning() {
        for fraction in [0.0, 0.01, 0.3, 0.5, 0.97, 0.999] {
            let start = 1_000_000.0 + fraction
            let environment = FakeEnvironment(timestamp: start)
            let presence = EnginePeer.Presence(status: .present(until: 1_000_005), lastActivity: 0)
            let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState)
            XCTAssertTrue(row.shownOnline())

            let finished = environment.advance(to: start + 3600.0)
            XCTAssertTrue(finished, "refresh loop did not settle (fraction \(fraction))")
            XCTAssertEqual(row.updates(), 1, "fraction \(fraction)")
            XCTAssertFalse(row.shownOnline())
            XCTAssertEqual(environment.pendingTimerCount, 0)
            withExtendedLifetime(row.manager) {}
        }
    }

    func testOnlineDotDisappearsAsSoonAsStatusExpires() {
        let environment = FakeEnvironment(timestamp: 1_000_000.4)
        let presence = EnginePeer.Presence(status: .present(until: 1_000_010), lastActivity: 0)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState, layoutCost: 0.0)

        // Still online during the last second of "until".
        environment.advance(to: 1_000_010.99)
        XCTAssertTrue(row.shownOnline())
        XCTAssertEqual(row.updates(), 0)
        // First moment the integer clock passes "until".
        environment.advance(to: 1_000_011.0)
        XCTAssertFalse(row.shownOnline())
        XCTAssertEqual(row.updates(), 1)
        withExtendedLifetime(row.manager) {}
    }

    // A chat list row shows only the online dot, so "last seen N minutes ago" ticks are wasted.
    func testOnlineStateModeDoesNotTickWhileOffline() {
        let environment = FakeEnvironment(timestamp: 1_000_000.0)
        let presence = EnginePeer.Presence(status: .present(until: 1_000_000 - 70), lastActivity: 0)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState)
        XCTAssertEqual(environment.pendingTimerCount, 0)
        environment.advance(to: 1_000_000.0 + 3600.0)
        XCTAssertEqual(row.updates(), 0)
        withExtendedLifetime(row.manager) {}
    }

    // Status text must change exactly when the label changes, with one wakeup per change.
    func testStatusTextRefreshesOncePerLabelChangeAndNeverLate() {
        let until: Int32 = 1_000_000
        let presence = EnginePeer.Presence(status: .present(until: until), lastActivity: 0)
        let environment = FakeEnvironment(timestamp: Double(until) - 2.5)
        var shown = statusLabel(presence, at: environment.currentTimestamp)
        var updates = 0
        var managerRef: PeerPresenceStatusManager?
        let manager = PeerPresenceStatusManager(mode: .statusText, environment: environment, update: {
            updates += 1
            shown = statusLabel(presence, at: environment.currentTimestamp)
            managerRef?.reset(presence: presence)
        })
        managerRef = manager
        manager.reset(presence: presence)

        var maxStaleness = 0.0
        var labelChanges = 0
        var previousTrue = shown
        var t = environment.currentTimestamp
        let end = Double(until) + 2.0 * 3600.0
        let step = 0.05
        var staleSince: Double?
        while t < end {
            t += step
            if !environment.advance(to: t, maxFires: 100) {
                XCTFail("refresh loop did not settle at \(t)")
                break
            }
            let trueLabel = statusLabel(presence, at: t)
            if trueLabel != previousTrue {
                labelChanges += 1
                previousTrue = trueLabel
            }
            if shown != trueLabel {
                if staleSince == nil {
                    staleSince = t
                }
                maxStaleness = max(maxStaleness, t - staleSince!)
            } else {
                staleSince = nil
            }
        }
        XCTAssertLessThanOrEqual(maxStaleness, 0.15, "label lagged by \(maxStaleness) s")
        // online -> just now -> 1..59 min -> hours: 61 changes. One extra wakeup at 31 s is allowed.
        XCTAssertEqual(labelChanges, 61)
        XCTAssertLessThanOrEqual(updates, labelChanges + 1, "\(updates) wakeups for \(labelChanges) label changes")
        withExtendedLifetime(manager) {}
    }

    func testNoTimersOrUpdatesInBackgroundAndSingleCatchUpOnForeground() {
        let environment = FakeEnvironment(timestamp: 1_000_000.0)
        let presence = EnginePeer.Presence(status: .present(until: 1_000_005), lastActivity: 0)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState)
        XCTAssertEqual(environment.pendingTimerCount, 1)

        environment.advance(to: 1_000_001.0)
        environment.isApplicationInBackground = true
        XCTAssertEqual(environment.pendingTimerCount, 0)
        environment.advance(to: 1_000_600.0)
        XCTAssertEqual(row.updates(), 0)
        XCTAssertTrue(row.shownOnline())

        environment.isApplicationInBackground = false
        XCTAssertEqual(row.updates(), 1)
        XCTAssertFalse(row.shownOnline())
        XCTAssertEqual(environment.pendingTimerCount, 0)
        withExtendedLifetime(row.manager) {}
    }

    func testForegroundBeforeDeadlineReschedulesRemainingTime() {
        let environment = FakeEnvironment(timestamp: 1_000_000.25)
        let presence = EnginePeer.Presence(status: .present(until: 1_000_100), lastActivity: 0)
        let row = self.makeRow(environment: environment, presence: presence, mode: .onlineState, layoutCost: 0.0)

        environment.isApplicationInBackground = true
        environment.advance(to: 1_000_050.0)
        environment.isApplicationInBackground = false
        XCTAssertEqual(row.updates(), 0)
        XCTAssertEqual(environment.pendingTimerCount, 1)
        XCTAssertEqual(environment.nextDeadline ?? 0.0, 1_000_101.0, accuracy: 0.001)

        environment.advance(to: 1_000_200.0)
        XCTAssertEqual(row.updates(), 1)
        XCTAssertFalse(row.shownOnline())
        withExtendedLifetime(row.manager) {}
    }

    func testResetToFinalStateCancelsPendingTimer() {
        let environment = FakeEnvironment(timestamp: 1_000_000.0)
        let online = EnginePeer.Presence(status: .present(until: 1_000_100), lastActivity: 0)
        var updates = 0
        let manager = PeerPresenceStatusManager(mode: .onlineState, environment: environment, update: {
            updates += 1
        })
        manager.reset(presence: online, isOnline: true)
        XCTAssertEqual(environment.pendingTimerCount, 1)
        manager.reset(presence: EnginePeer.Presence(status: .lastWeek(isHidden: false), lastActivity: 0), isOnline: false)
        XCTAssertEqual(environment.pendingTimerCount, 0)
        environment.advance(to: 1_001_000.0)
        XCTAssertEqual(updates, 0)
    }

    func testDeallocatedManagerStopsTimerAndListener() {
        let environment = FakeEnvironment(timestamp: 1_000_000.0)
        var updates = 0
        var manager: PeerPresenceStatusManager? = PeerPresenceStatusManager(mode: .onlineState, environment: environment, update: {
            updates += 1
        })
        manager?.reset(presence: EnginePeer.Presence(status: .present(until: 1_000_010), lastActivity: 0), isOnline: true)
        XCTAssertEqual(environment.pendingTimerCount, 1)
        manager = nil
        XCTAssertEqual(environment.pendingTimerCount, 0)
        environment.isApplicationInBackground = true
        environment.isApplicationInBackground = false
        XCTAssertEqual(updates, 0)
    }

    // Wakeups for one contact "last seen" within the hour, statusText mode (e.g. a members list row).
    func testBenchmarkStatusTextWakeupsPerHour() {
        let until: Int32 = 1_000_000
        let presence = EnginePeer.Presence(status: .present(until: until), lastActivity: 0)
        let environment = FakeEnvironment(timestamp: Double(until) + 61.3)
        var managerRef: PeerPresenceStatusManager?
        var updates = 0
        let counting = PeerPresenceStatusManager(mode: .statusText, environment: environment, update: {
            updates += 1
            managerRef?.reset(presence: presence)
        })
        managerRef = counting
        counting.reset(presence: presence)
        environment.advance(to: Double(until) + 3600.0 + 10.0)
        print("PeerPresenceStatusManager statusText wakeups in the first hour after going offline: \(updates)")
        XCTAssertLessThanOrEqual(updates, 60)
        withExtendedLifetime(counting) {}
    }

    // Real timers on the main run loop: refreshes and main-thread time spent when "online until"
    // expires, with ~1 ms of work per refresh (a chat list row layout is 1-3 ms on device).
    func testBenchmarkRealTimerExpiry() {
        let now = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
        let until = Int32(now) + 1
        let presence = EnginePeer.Presence(status: .present(until: until), lastActivity: 0)
        var updates = 0
        var busy = 0.0
        var managerRef: PeerPresenceStatusManager?
        let manager = PeerPresenceStatusManager(mode: .onlineState, update: {
            updates += 1
            let start = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - start < 0.001 {
            }
            busy += CFAbsoluteTimeGetCurrent() - start
            let timestamp = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
            managerRef?.reset(presence: presence, isOnline: until >= Int32(timestamp))
        })
        managerRef = manager
        manager.reset(presence: presence, isOnline: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: (Double(until) + 2.2) - now))
        print("PeerPresenceStatusManager real-timer expiry: \(updates) refreshes, \(Int(busy * 1000.0)) ms busy")
        XCTAssertEqual(updates, 1)
        managerRef = nil
    }
}
