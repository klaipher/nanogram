import Foundation
import SwiftSignalKit

func pendingUploadFallback<T, E>(_ fallback: T) -> (Signal<T, E>) -> Signal<T, E> {
    return { signal in
        return Signal { subscriber in
            let emitted = Atomic<Bool>(value: false)
            return signal.start(next: { value in
                let _ = emitted.swap(true)
                subscriber.putNext(value)
            }, error: { error in
                subscriber.putError(error)
            }, completed: {
                if !emitted.with({ $0 }) {
                    subscriber.putNext(fallback)
                }
                subscriber.putCompletion()
            })
        }
    }
}

struct PendingUploadProgressMilestones {
    private var lastReached: Int = 0

    mutating func reached(_ progress: Float) -> [Int] {
        var result: [Int] = []
        for milestone in [25, 50, 75, 100] {
            if milestone > self.lastReached && progress >= Float(milestone) / 100.0 - 0.0001 {
                result.append(milestone)
                self.lastReached = milestone
            }
        }
        return result
    }
}

/// A step of a pending message. Goes to the log only, which the user's logging setting controls.
func pendingMessageLog(_ what: @autoclosure () -> String) {
    Logger.shared.log("PendingMessage", what())
}

/// A pending message that failed. Also goes to the critical log, which the logging setting does not
/// control, so the text must not name a peer.
func pendingMessageFailureLog(_ what: @autoclosure () -> String) {
    let string = what()
    Logger.shared.log("PendingMessage", string)
    Logger.shared.shortLog("PendingMessage", string)
}

/// What a pending send does after its request failed. Named in the same failure-log line, so a send that is sent
/// again with a fresh file reference (and then goes through) does not read as a lost message.
enum PendingSendFailureOutcome: Equatable {
    /// Sent again, once, with fresh file references or a new upload (`forcedReuploadOnce`): for the listed items
    /// of a group, or for the whole send when `items` is nil or empty.
    case sendingAgainWithFreshMedia(items: [Int]?)
    /// Marked failed. `afterFreshTry` is true when the one fresh-reference-or-upload try was already used.
    case failing(afterFreshTry: Bool)
    /// The message is no longer pending (sent, deleted, or the manager is gone): nothing more is done.
    case noLongerPending
}

/// "<subject> request failed <code> <text>, <outcome>, <context>". The prefix stays as it was, so log readers that
/// look for "request failed" still match. No peer ids or names: the line goes to the critical log.
func pendingSendFailureLogText(_ subject: String, code: Int32, text: String, outcome: PendingSendFailureOutcome, context: String) -> String {
    let outcomeText: String
    switch outcome {
    case let .sendingAgainWithFreshMedia(items):
        if let items, !items.isEmpty {
            outcomeText = "sending again with a fresh reference or upload for item \(items.map { "\($0)" }.joined(separator: ", ")) (once)"
        } else {
            outcomeText = "sending again with a fresh reference or upload (once)"
        }
    case let .failing(afterFreshTry):
        outcomeText = afterFreshTry ? "failing it, fresh reference or upload already tried" : "failing it"
    case .noLongerPending:
        outcomeText = "no longer pending"
    }
    var result = "\(subject) request failed \(code) \(text), \(outcomeText)"
    if !context.isEmpty {
        result += ", \(context)"
    }
    return result
}
