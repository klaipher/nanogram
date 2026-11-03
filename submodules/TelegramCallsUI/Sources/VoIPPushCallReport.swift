import Foundation

/// The obligation a VoIP push brings: since iOS 13 an app must report an incoming call to CallKit
/// for every VoIP push before it finishes handling it, or iOS terminates it and, after repeated
/// misses, stops delivering VoIP pushes to it (only apps with the unrestricted-voip entitlement,
/// like the official one, are exempt). A push the app cannot use (no account state yet, an unknown
/// key, a payload it cannot decrypt or read) therefore still reports a call, which is ended at once.
///
/// Not thread-safe: use it from the queue PushKit delivers on (main).
public final class VoIPPushCallReport {
    private let reportFailedCall: () -> Void
    private let completion: () -> Void
    private var isReported = false
    private var isCompleted = false

    public init(reportFailedCall: @escaping () -> Void, completion: @escaping () -> Void) {
        self.reportFailedCall = reportFailedCall
        self.completion = completion
    }

    /// A real call was reported to CallKit for this push.
    public func callReported() {
        self.isReported = true
    }

    /// Reports and ends a placeholder call unless a call was already reported.
    public func reportFailedCallIfNeeded() {
        if !self.isReported {
            self.isReported = true
            self.reportFailedCall()
        }
    }

    /// Finishes handling the push, reporting a placeholder call first if nothing was reported.
    public func complete() {
        if self.isCompleted {
            return
        }
        self.isCompleted = true
        self.reportFailedCallIfNeeded()
        self.completion()
    }
}
