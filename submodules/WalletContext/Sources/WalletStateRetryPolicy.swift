import Foundation

struct WalletStateRetryPolicy: Equatable {
    static let initialDelay: TimeInterval = 5
    static let maximumDelay: TimeInterval = 600

    private(set) var failures = 0

    var delay: TimeInterval {
        let steps = min(max(self.failures - 1, 0), 10)
        return min(Self.initialDelay * pow(2, Double(steps)), Self.maximumDelay)
    }

    mutating func recordFailure() {
        self.failures += 1
    }

    mutating func reset() {
        self.failures = 0
    }

    func shouldRetry(hasWallet: Bool, hasRefreshDemand: Bool) -> Bool {
        hasWallet || hasRefreshDemand
    }
}
