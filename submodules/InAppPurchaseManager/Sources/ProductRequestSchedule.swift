import Foundation

/// Decides when `InAppPurchaseManager` asks StoreKit for its products.
///
/// While there are no products the request is retried, with a delay that doubles from 10 s up to
/// `maximumRetryDelay`, and only while the app is in the foreground. Every `SKRequest` holds a
/// background task of its own while it runs, so a retry loop that kept going in the background kept the
/// app from being suspended: a build whose bundle has no products retried every 10-40 s forever, and on
/// device that kept the app awake for minutes after it was left. Prices are only shown in the
/// foreground, and a screen that shows them forces a request at once.
public struct InAppPurchaseProductRequestSchedule: Equatable {
    public enum Action: Equatable {
        case startRequest
        case cancelRequest
        case scheduleRetry(Double)
        case cancelRetry
    }

    public static let initialRetryDelay: Double = 10.0
    public static let maximumRetryDelay: Double = 300.0

    public private(set) var isInBackground: Bool
    private var hasProducts = false
    private var isRequesting = false
    private var isRetryScheduled = false
    private var failureCount = 0
    // A request was wanted while in the background (or one was cancelled there).
    private var isDeferred = false

    public init(isInBackground: Bool) {
        self.isInBackground = isInBackground
    }

    public static func retryDelay(failureCount: Int) -> Double {
        let exponent = min(max(failureCount - 1, 0), 16)
        return min(initialRetryDelay * Double(1 << exponent), maximumRetryDelay)
    }

    /// Products are wanted. `force` is for a screen that shows prices: it does not wait for a pending retry.
    public mutating func requestNeeded(force: Bool) -> [Action] {
        if self.hasProducts || self.isRequesting {
            return []
        }
        if self.isInBackground {
            self.isDeferred = true
            return []
        }
        if self.isRetryScheduled {
            if !force {
                return []
            }
            self.isRetryScheduled = false
            self.isRequesting = true
            return [.cancelRetry, .startRequest]
        }
        self.isRequesting = true
        return [.startRequest]
    }

    /// The running request answered, failed or timed out.
    public mutating func requestFinished(receivedProducts: Bool) -> [Action] {
        if !self.isRequesting {
            return []
        }
        self.isRequesting = false
        if receivedProducts {
            self.hasProducts = true
            self.failureCount = 0
            self.isDeferred = false
            if self.isRetryScheduled {
                self.isRetryScheduled = false
                return [.cancelRetry]
            }
            return []
        }
        self.failureCount += 1
        if self.isInBackground {
            self.isDeferred = true
            return []
        }
        self.isRetryScheduled = true
        return [.scheduleRetry(InAppPurchaseProductRequestSchedule.retryDelay(failureCount: self.failureCount))]
    }

    public mutating func retryFired() -> [Action] {
        if !self.isRetryScheduled {
            return []
        }
        self.isRetryScheduled = false
        return self.requestNeeded(force: false)
    }

    public mutating func enteredBackground() -> [Action] {
        if self.isInBackground {
            return []
        }
        self.isInBackground = true
        if self.hasProducts {
            return []
        }
        var actions: [Action] = []
        if self.isRetryScheduled {
            self.isRetryScheduled = false
            self.isDeferred = true
            actions.append(.cancelRetry)
        }
        if self.isRequesting {
            self.isRequesting = false
            self.isDeferred = true
            actions.append(.cancelRequest)
        }
        return actions
    }

    public mutating func enteredForeground() -> [Action] {
        if !self.isInBackground {
            return []
        }
        self.isInBackground = false
        if !self.isDeferred || self.hasProducts || self.isRequesting || self.isRetryScheduled {
            return []
        }
        self.isDeferred = false
        if self.failureCount == 0 {
            self.isRequesting = true
            return [.startRequest]
        }
        self.isRetryScheduled = true
        return [.scheduleRetry(InAppPurchaseProductRequestSchedule.retryDelay(failureCount: self.failureCount))]
    }
}
