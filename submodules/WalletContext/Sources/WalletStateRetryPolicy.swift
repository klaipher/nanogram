import Foundation

/// Retry timing for a failed server wallet-state request.
///
/// The wallet state is only unknown until the first successful answer (including a definite "no wallet"),
/// so a failure must always be retried or an existing wallet is never discovered. What changes is how
/// patient we are: unattended retries back off to ten minutes to save battery, while a visible wallet
/// screen (or pending transfer) caps the wait so the user is never left looking at stale data.
struct WalletStateRetryPolicy: Equatable {
    static let initialDelay: TimeInterval = 5
    static let maximumDelay: TimeInterval = 600
    static let maximumDelayWithDemand: TimeInterval = 20

    private(set) var failures = 0

    func delay(hasRefreshDemand: Bool) -> TimeInterval {
        let steps = min(max(self.failures - 1, 0), 10)
        let backoff = min(Self.initialDelay * pow(2, Double(steps)), Self.maximumDelay)
        return hasRefreshDemand ? min(backoff, Self.maximumDelayWithDemand) : backoff
    }

    mutating func recordFailure() {
        self.failures += 1
    }

    mutating func reset() {
        self.failures = 0
    }
}
