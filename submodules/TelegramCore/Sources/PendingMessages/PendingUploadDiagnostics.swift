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
