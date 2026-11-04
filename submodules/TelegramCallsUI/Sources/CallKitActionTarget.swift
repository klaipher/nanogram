import Foundation

enum CallKitActionTarget: Equatable {
    case personalCall
    case groupCall
    case none
}

/// Which call a CallKit end action is for. The action carries the UUID of a CallKit call, which can be a stale or
/// placeholder one; only the current one-to-one call whose UUID it names is hung up. A group call keeps taking the
/// actions that do not name the one-to-one call.
func callKitActionTarget(uuid: UUID, personalCallId: UUID?, hasGroupCall: Bool) -> CallKitActionTarget {
    if let personalCallId, personalCallId == uuid {
        return .personalCall
    }
    return hasGroupCall ? .groupCall : .none
}

/// An answer action answers only the one-to-one call whose UUID it names.
func callKitActionAnswersPersonalCall(uuid: UUID, personalCallId: UUID?) -> Bool {
    return personalCallId == uuid
}
