import Foundation
import SwiftSignalKit
import MtProtoKit
import Reachability

// Nanogram-only (upstream: no). What a failed send or upload may do to a pending message. The red "!"
// (`MessageFlags.Failed`) is a final state the user has to clear by hand, so a transient problem must not
// reach it. The reference clients (TDLib, Android, Desktop) classify by code: a negative code or a code of
// 500 and above is retried, every other 4xx is final at once. See NANOGRAM-CHANGES.md, "Send failures".

enum PendingSendFailureClass: Equatable {
    /// The server refused the message for good (`PEER_FLOOD`, `CHAT_WRITE_FORBIDDEN`, `MEDIA_EMPTY`, ...):
    /// fail it now and tell the user.
    case permanent
    /// A transport, server or engine problem: send again after a delay, fail only when the budget is spent.
    case transient
    /// The server lost the uploaded file (`FILE_PART_N_MISSING`, `FILE_PARTS_INVALID`, `FILE_ID_INVALID`):
    /// upload it again, once.
    case reupload
}

/// Texts that the transport (the Rust engine or the bridge) invents. They carry no server decision about the
/// message, so they are never final.
private let pendingSendSyntheticErrorPrefixes: [String] = [
    "PROTOCOL_ERROR_",
    "ENGINE_SWITCHED",
    "TL_PARSING_ERROR",
    "TL_VERIFICATION_ERROR"
]

func classifyPendingSendError(code: Int32, text: String) -> PendingSendFailureClass {
    if (text.hasPrefix("FILE_PART_") && text.hasSuffix("_MISSING")) || text.hasPrefix("FILE_PARTS_INVALID") || text.hasPrefix("FILE_ID_INVALID") {
        return .reupload
    }
    for prefix in pendingSendSyntheticErrorPrefixes {
        if text.hasPrefix(prefix) {
            return .transient
        }
    }
    if code < 0 || code >= 500 {
        return .transient
    }
    return .permanent
}

enum PendingSendRetryDecision: Equatable {
    case retry(after: Double)
    case fail
}

/// Count-only budget (no wall-clock gate, so it stays under the 10 minute launch expiry in Postbox).
enum PendingSendRetryPolicy {
    /// The send RPC is sent at most this many times in total (the first try included).
    static let maximumSendAttempts = 5
    /// The upload is started at most this many times in total.
    static let maximumUploadAttempts = 3
    private static let delays: [Double] = [2.0, 4.0, 8.0, 16.0, 30.0]

    static func delay(afterFailedAttempt attempt: Int) -> Double {
        if attempt < 1 {
            return self.delays[0]
        }
        return self.delays[min(attempt, self.delays.count) - 1]
    }

    static func decision(failureClass: PendingSendFailureClass, failedAttempts: Int, maximumAttempts: Int) -> PendingSendRetryDecision {
        switch failureClass {
        case .permanent, .reupload:
            return .fail
        case .transient:
            if failedAttempts >= maximumAttempts {
                return .fail
            }
            return .retry(after: self.delay(afterFailedAttempt: failedAttempts))
        }
    }
}

/// One saveFilePart/saveBigFilePart is retried (same file id, same part index, same bytes, so it is idempotent)
/// up to four times for a transient error before the whole upload fails. A final 4xx fails the part at once.
enum PendingUploadPartRetryPolicy {
    static let maximumRetries = 4
    private static let delays: [Double] = [0.5, 1.0, 2.0, 4.0]

    static func delay(code: Int32, text: String, failedAttempts: Int) -> Double? {
        guard classifyPendingSendError(code: code, text: text) == .transient else {
            return nil
        }
        if failedAttempts < 1 || failedAttempts > self.maximumRetries {
            return nil
        }
        return self.delays[failedAttempts - 1]
    }
}

/// Wraps one part upload: a transient server error is retried (see `PendingUploadPartRetryPolicy`).
/// Nanogram-only. The same signal is subscribed again, so the part keeps its index and its bytes, and the
/// encryption state of a secret chat file is not advanced twice.
func pendingUploadPartRetrying(_ signal: Signal<Void, UploadPartError>) -> Signal<Void, UploadPartError> {
    return signal |> pendingRetryingWithBackoff(queue: Queue.concurrentDefaultQueue(), decide: { (error: UploadPartError, failed: Int) -> Double? in
        if case let .server(code, text) = error {
            return PendingUploadPartRetryPolicy.delay(code: code, text: text, failedAttempts: failed)
        }
        return nil
    }, onRetry: { (error: UploadPartError, failed: Int, delay: Double) in
        if case let .server(code, text) = error {
            pendingMessageLog("upload part failed \(code) \(text), attempt \(failed), again in \(delay) s")
        }
    })
}

/// Subscribes to `signal` again after a failure the `decide` closure answers with a delay. A signal that
/// already produced a value for which `blocksRetry` is true (the content of an upload) is never repeated.
/// The same signal is subscribed again, so a request keeps its random id.
func pendingRetryingWithBackoff<T, E>(queue: Queue, decide: @escaping (E, Int) -> Double?, blocksRetry: @escaping (T) -> Bool = { _ in false }, onRetry: @escaping (E, Int, Double) -> Void = { _, _, _ in }) -> (Signal<T, E>) -> Signal<T, E> {
    return { signal in
        return Signal { subscriber in
            let subscription = MetaDisposable()
            let timerDisposable = MetaDisposable()
            let attempts = Atomic<Int>(value: 0)
            let blocked = Atomic<Bool>(value: false)
            
            // The subscription and the pending timer are kept apart: a signal that fails synchronously calls the
            // error handler before `start` returns, and that must not dispose the timer it has just armed.
            // Each try gets its own holder, installed before the signal starts: a retry whose timer fires before
            // the previous `start` has returned replaces (and disposes) the old holder, instead of the old
            // `start` later overwriting, and so cancelling, the retry's subscription.
            func start() {
                let current = MetaDisposable()
                subscription.set(current)
                current.set(signal.start(next: { value in
                    if blocksRetry(value) {
                        let _ = blocked.swap(true)
                    }
                    subscriber.putNext(value)
                }, error: { error in
                    let failed = attempts.modify { $0 + 1 }
                    if !blocked.with({ $0 }), let delay = decide(error, failed) {
                        onRetry(error, failed, delay)
                        let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: {
                            start()
                        }, queue: queue)
                        timerDisposable.set(ActionDisposable {
                            timer.invalidate()
                        })
                        timer.start()
                    } else {
                        subscriber.putError(error)
                    }
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            
            start()
            return ActionDisposable {
                subscription.dispose()
                timerDisposable.dispose()
            }
        }
    }
}

/// The send RPC (`sendMessage`, `sendMedia`, `sendMultiMedia`, ...) is sent again with the same random id and
/// the content that is already uploaded, after a transient error, up to `PendingSendRetryPolicy.maximumSendAttempts`
/// tries. A permanent error, a lost file part (handled by the caller's one re-upload) and a paid message
/// (`enabled` is false, so no Stars are spent twice) are passed on at once.
func pendingSendRetrying<T>(queue: Queue, enabled: Bool, logName: String) -> (Signal<T, MTRpcError>) -> Signal<T, MTRpcError> {
    if !enabled {
        return { $0 }
    }
    return pendingRetryingWithBackoff(queue: queue, decide: { (error: MTRpcError, failed: Int) -> Double? in
        let failureClass = classifyPendingSendError(code: error.errorCode, text: error.errorDescription)
        switch PendingSendRetryPolicy.decision(failureClass: failureClass, failedAttempts: failed, maximumAttempts: PendingSendRetryPolicy.maximumSendAttempts) {
        case let .retry(after):
            return after
        case .fail:
            return nil
        }
    }, onRetry: { (error: MTRpcError, failed: Int, delay: Double) in
        pendingMessageLog("\(logName) request failed \(error.errorCode) \(error.errorDescription ?? ""), attempt \(failed), again in \(delay) s")
    })
}

/// How a failed pending message is shown to the user (the Retry menu). Pure, so the mapping is tested.
public enum PendingMessageFailureDescription: Equatable {
    /// The server refused it for good (`PEER_FLOOD`, forbidden, ...): "Not allowed in this chat".
    case notAllowed
    /// A rate limit (`SENDING_TOO_FAST`, `PEER_FLOOD`, `SLOWMODE_WAIT`): "Too many messages".
    case tooManyMessages
    /// The media was refused (`MEDIA_EMPTY`, ...): "Media rejected".
    case mediaRejected
    /// No error code was stored: the message expired while the app was closed or in the background.
    case notSentInTime
    /// Anything else (a network problem or an unknown error): "Could not send".
    case couldNotSend
}

public extension PendingMessageFailureDescription {
    /// Plain English, as the other Nanogram-only screens (no Localizable.strings key, so no upstream merge noise).
    var text: String {
        switch self {
        case .notAllowed:
            return "Not allowed in this chat"
        case .tooManyMessages:
            return "Too many messages"
        case .mediaRejected:
            return "Media rejected"
        case .notSentInTime:
            return "Not sent in time. Tap to retry."
        case .couldNotSend:
            return "Could not send. Tap to retry."
        }
    }
}

public func pendingMessageFailureDescription(sendErrorCode: String?) -> PendingMessageFailureDescription {
    guard let code = sendErrorCode else {
        return .notSentInTime
    }
    if code.hasPrefix("PEER_FLOOD") || code.hasPrefix("SENDING_TOO_FAST") || code.hasPrefix("SLOWMODE_WAIT") || code.hasPrefix("SCHEDULE_TOO_MUCH") {
        return .tooManyMessages
    }
    if code.hasPrefix("MEDIA_EMPTY") || code.hasPrefix("MEDIA_INVALID") || code.hasPrefix("PHOTO_INVALID") || code.hasPrefix("IMAGE_PROCESS_FAILED") || code.hasPrefix("MESSAGE_EMPTY") {
        return .mediaRejected
    }
    if code.hasPrefix("USER_BANNED_IN_CHANNEL") || (code.hasPrefix("CHAT_") && code.hasSuffix("_FORBIDDEN")) || code.hasPrefix("USER_IS_BLOCKED") || code.hasPrefix("PRIVACY_PREMIUM_REQUIRED") || code.hasPrefix("VOICE_MESSAGES_FORBIDDEN") || code.hasPrefix("PEER_ID_INVALID") || code.hasPrefix("CHAT_ADMIN_REQUIRED") {
        return .notAllowed
    }
    return .couldNotSend
}

/// What the failure log says about an upload error. No peer ids.
func pendingUploadErrorDescription(_ error: PendingMessageUploadError) -> String {
    switch error {
    case .generic:
        return "local or unknown error"
    case let .server(code, text):
        return "\(code) \(text)"
    }
}

/// The `sendErrorCode` stored on the failed message: the real server text when there is one, so the Retry menu
/// can say why. A local or unknown upload error stays "internal".
func pendingUploadErrorCode(_ error: PendingMessageUploadError) -> String {
    switch error {
    case .generic:
        return "internal"
    case let .server(_, text):
        return text.isEmpty ? "internal" : text
    }
}

private final class PendingFailureNetworkObserver {
    static let shared = PendingFailureNetworkObserver()
    private let value = Atomic<String>(value: "unknown")
    private var disposable: Disposable?

    private init() {
        self.disposable = (Reachability.networkType |> deliverOnMainQueue).start(next: { [value] type in
            let _ = value.swap("\(type)")
        })
    }

    var current: String {
        return self.value.with { $0 }
    }
}

/// "wifi", "cellular", "none" or "unknown" (not known yet). Read when a failure is logged.
func pendingFailureNetworkDescription() -> String {
    return PendingFailureNetworkObserver.shared.current
}
