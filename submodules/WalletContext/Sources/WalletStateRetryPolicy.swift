import Foundation

/// What a failed server wallet-state request tells us.
enum WalletStateFailureKind: Equatable {
    /// The server said WALLET_UNAVAILABLE for this account. Asking again is pointless for now, but the server may
    /// enable the wallet later in the session, so one attempt per `authoritativeRetryInterval` is still made (and
    /// opening the wallet asks at once).
    case authoritative
    /// Network, server or flood-wait trouble; the answer is still unknown. `minimumDelay` is a server-imposed wait.
    case transient(minimumDelay: TimeInterval)
}

extension WalletStateFailureKind {
    /// TelegramCore-free mapping of a `WalletGetStateError`: authoritative only for WALLET_UNAVAILABLE, a flood wait is
    /// a transient failure with the wait the server asked for, everything else is transient.
    init(isAuthoritative: Bool, floodWaitSeconds: Int32?) {
        if isAuthoritative {
            self = .authoritative
        } else if let seconds = floodWaitSeconds {
            self = .transient(minimumDelay: TimeInterval(max(0, seconds)))
        } else {
            self = .transient(minimumDelay: 0)
        }
    }
}

/// Retry timing for a failed server wallet-state request.
///
/// The wallet state is unknown until the first successful answer (including a definite "no wallet"), so a
/// transient failure is retried with exponential backoff (5 s doubling to 10 min; 20 s while a wallet screen or
/// pending transfer is visible). The backoff survives foreground and network-resume events: only a visible
/// wallet screen (`resetForUserDemand`) or a success restarts it. An authoritative failure stops retries until
/// that same user demand. Attempts per hour are bounded either way, and a new context (app launch, account
/// switch) always gets one attempt.
struct WalletStateRetryPolicy: Equatable {
    static let initialDelay: TimeInterval = 5
    static let maximumDelay: TimeInterval = 600
    static let maximumDelayWithDemand: TimeInterval = 20
    static let attemptWindow: TimeInterval = 3600
    static let authoritativeRetryInterval: TimeInterval = 3600
    static let maximumAttemptsPerWindow = 8
    static let maximumAttemptsPerWindowWithDemand = 120

    enum Gate: Equatable {
        case allow
        case wait(TimeInterval)
    }

    private(set) var failures = 0
    private(set) var isAuthoritativelyStopped = false
    private var lastFailureAt: Date?
    private var lastMinimumDelay: TimeInterval = 0
    private var attempts: [Date] = []

    func delay(hasRefreshDemand: Bool) -> TimeInterval {
        let steps = min(max(self.failures - 1, 0), 10)
        let backoff = min(Self.initialDelay * pow(2, Double(steps)), Self.maximumDelay)
        return hasRefreshDemand ? min(backoff, Self.maximumDelayWithDemand) : backoff
    }

    /// Whether a request may start now or must wait.
    func gate(hasRefreshDemand: Bool, now: Date) -> Gate {
        var wait: TimeInterval = 0
        if self.isAuthoritativelyStopped, let lastFailureAt = self.lastFailureAt {
            wait = max(wait, lastFailureAt.addingTimeInterval(Self.authoritativeRetryInterval).timeIntervalSince(now))
        }
        if let lastFailureAt = self.lastFailureAt {
            let due = lastFailureAt.addingTimeInterval(max(self.delay(hasRefreshDemand: hasRefreshDemand), self.lastMinimumDelay))
            wait = max(wait, due.timeIntervalSince(now))
        }
        let limit = hasRefreshDemand ? Self.maximumAttemptsPerWindowWithDemand : Self.maximumAttemptsPerWindow
        let recent = self.attempts.filter { now.timeIntervalSince($0) < Self.attemptWindow }
        if recent.count >= limit, let oldest = recent.first {
            wait = max(wait, oldest.addingTimeInterval(Self.attemptWindow).timeIntervalSince(now))
        }
        return wait > 0 ? .wait(wait) : .allow
    }

    mutating func recordAttempt(at now: Date) {
        self.attempts.removeAll { now.timeIntervalSince($0) >= Self.attemptWindow }
        self.attempts.append(now)
    }

    mutating func recordFailure(_ kind: WalletStateFailureKind = .transient(minimumDelay: 0), at now: Date = Date()) {
        self.failures += 1
        self.lastFailureAt = now
        switch kind {
        case .authoritative:
            self.isAuthoritativelyStopped = true
            self.lastMinimumDelay = 0
        case let .transient(minimumDelay):
            self.isAuthoritativelyStopped = false
            self.lastMinimumDelay = max(0, minimumDelay)
        }
    }

    /// The user is looking at the wallet again: forget the backoff and any authoritative stop, keep the hourly count.
    mutating func resetForUserDemand() {
        self.clearFailureState()
    }

    /// A successful answer ends the whole episode.
    mutating func reset() {
        self.clearFailureState()
        self.attempts.removeAll()
    }

    private mutating func clearFailureState() {
        self.failures = 0
        self.isAuthoritativelyStopped = false
        self.lastFailureAt = nil
        self.lastMinimumDelay = 0
    }
}
