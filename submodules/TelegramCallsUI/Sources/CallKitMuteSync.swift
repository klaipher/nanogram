import Foundation

/// What CallKit believes about the microphone of each of its calls, so the app tells it about a mute the user did in the
/// app and does not answer CallKit's own mute action with the same action again. A call starts unmuted.
struct CallKitMuteSync: Equatable {
    private var muted: [UUID: Bool] = [:]
    
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
    
    mutating func forget(uuid: UUID) {
        self.muted[uuid] = nil
    }
    
    mutating func forgetAll() {
        self.muted.removeAll()
    }
}
