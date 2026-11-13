import Foundation
import CallKit
import TelegramCore

/// How CallKit records a call that ended: a call nobody answered is a missed call in Recents and
/// on the lock screen, a failed one is a failure, anything the other side or the user ended is a
/// normal end.
func callKitEndedReason(_ reason: CallSessionTerminationReason?) -> CXCallEndedReason {
    switch reason {
    case .ended(.missed):
        return .unanswered
    case .error:
        return .failed
    case .ended(.hungUp), .ended(.busy), .ended(.switchedToConference), .none:
        return .remoteEnded
    }
}
