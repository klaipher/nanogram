import Foundation

/// How long the automatic TON Connect session refresh stays quiet after a successful one.
///
/// Log of 2026-11-07: `wallet.tonConnectGetSessions` was sent 65 times in 93 minutes, once per foreground
/// flip. New requests and session changes reach the app through updates while it is in the foreground, so
/// the refresh on foreground is a safety net that does not need to run on every flip. It still runs at once
/// when the user is looking at a wallet screen, for every explicit refresh (the Apps screen, a wallet
/// identity change, a pending disconnect) and the first time after launch.
struct WalletTonConnectRefreshThrottle: Equatable {
    static let interval: TimeInterval = 300

    private(set) var lastSuccessAt: Date?

    /// `isAutomatic`: the refresh is only caused by the app coming to the foreground, the network coming back
    /// or the feature becoming available. `hasWalletScreen`: a wallet or TON Connect screen is open.
    func shouldRefresh(isAutomatic: Bool, hasWalletScreen: Bool, now: Date) -> Bool {
        if !isAutomatic || hasWalletScreen {
            return true
        }
        guard let lastSuccessAt else {
            return true
        }
        let elapsed = now.timeIntervalSince(lastSuccessAt)
        return elapsed < 0 || elapsed >= Self.interval
    }

    mutating func recordSuccess(at now: Date) {
        self.lastSuccessAt = now
    }

    /// Forget the last success, e.g. when the wallet identity changes and the sessions belong to another wallet.
    mutating func reset() {
        self.lastSuccessAt = nil
    }
}

/// A `WALLET_UNAVAILABLE` answer remembered across launches for a few minutes.
///
/// The in-process retry policy already stops asking after that answer, but every launch starts a new context
/// and asks once (log of 2026-11-07: 4 answers, two of them 24 s and 2 min after the previous one). A launch
/// within `lifetime` of an answer starts out as if it had just received it. A visible wallet screen resets the
/// policy (`WalletStateRetryPolicy.resetForUserDemand`) and asks at once, as before.
enum WalletUnavailableMemory {
    static let lifetime: TimeInterval = 300

    /// The time of a remembered answer, or nil when none is stored, it is older than `lifetime` or it lies in the future.
    static func rememberedAnswerDate(stored: TimeInterval?, now: Date) -> Date? {
        guard let stored else {
            return nil
        }
        let date = Date(timeIntervalSince1970: stored)
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < lifetime ? date : nil
    }
}
