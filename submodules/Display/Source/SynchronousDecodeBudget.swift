import Foundation

/// Limits how much main-thread time image views may spend on synchronous image loads in one burst.
///
/// The first window of a chat is built with synchronous loads so that photos are drawn in the first frame, but a
/// photo that is not already decoded costs 30-44 ms on the main thread (resource read, JPEG decode, draw), and a
/// media-heavy chat has several: 177 and 152 ms busy streaks at chat open. Each synchronous load now asks for
/// permission and reports what it cost. Loads that are cheap (the data is cached) keep going until the burst has
/// spent `limit`; after that, the remaining images of the burst load off the main thread and show their placeholder
/// first. The first request of a burst is always granted, so the newest photo (nearest the input) is drawn at once.
/// A burst ends when `burstGap` passes without a request. Main thread only.
public final class SynchronousDecodeBudget {
    public let limit: Double
    public let burstGap: Double
    private var spent: Double = 0.0
    private var lastActivity: Double?

    public init(limit: Double = 0.012, burstGap: Double = 0.3) {
        self.limit = limit
        self.burstGap = burstGap
    }

    /// The budget used by chat message media.
    public static let chatMedia = SynchronousDecodeBudget()

    /// Whether a synchronous load may run now. `now` is a monotonic clock in seconds.
    public func allowsSynchronousLoad(now: Double) -> Bool {
        self.startNewBurstIfNeeded(now: now)
        return self.spent < self.limit
    }

    /// Reports the main-thread time a granted synchronous load took.
    public func recordSynchronousLoad(duration: Double, now: Double) {
        self.startNewBurstIfNeeded(now: now)
        self.spent += max(0.0, duration)
        self.lastActivity = now
    }

    private func startNewBurstIfNeeded(now: Double) {
        if let lastActivity = self.lastActivity, now - lastActivity > self.burstGap {
            self.spent = 0.0
            self.lastActivity = nil
        }
    }
}
