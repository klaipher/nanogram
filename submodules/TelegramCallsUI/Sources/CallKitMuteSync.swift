import Foundation

/// What CallKit believes about the microphone of each of its calls, so the app tells it about a mute the user did in the
/// app and does not answer CallKit's own mute action with the same action again. A call starts unmuted.
struct CallKitMuteSync: Equatable {
    private var muted: [UUID: Bool] = [:]
    private var appActions = Set<UUID>()
    
    /// CallKit asked for this state itself (the lock screen, the system call UI, an AirPods gesture, Siri).
    mutating func systemSet(uuid: UUID, isMuted: Bool) {
        self.muted[uuid] = isMuted
    }
    
    /// Whether the app has to report `isMuted` for the call. Remembers it when it does.
    mutating func shouldReport(uuid: UUID, isMuted: Bool) -> Bool {
        if (self.muted[uuid] ?? false) == isMuted {
            return false
        }
        self.muted[uuid] = isMuted
        return true
    }
    
    /// The app sent a mute action of its own (`CXAction.uuid`). CallKit performs it on the provider like any other.
    mutating func appRequested(actionId: UUID) {
        self.appActions.insert(actionId)
    }
    
    /// Whether an action CallKit performs is one the app sent itself. It is already applied to the call, and applying it a
    /// second time could undo a newer tap that came in between. Answers yes once per action.
    mutating func isAppRequested(actionId: UUID) -> Bool {
        return self.appActions.remove(actionId) != nil
    }
    
    /// CallKit refused the app's action, so it still shows `previous`.
    mutating func appRequestFailed(actionId: UUID, uuid: UUID, previous: Bool) {
        self.appActions.remove(actionId)
        self.muted[uuid] = previous
    }
    
    func isMuted(uuid: UUID) -> Bool {
        return self.muted[uuid] ?? false
    }
    
    mutating func forget(uuid: UUID) {
        self.muted[uuid] = nil
    }
    
    mutating func forgetAll() {
        self.muted.removeAll()
        self.appActions.removeAll()
    }
}
