import Foundation

enum AudioOutputRequestDecision: Equatable {
    case apply
    case skipAlreadyInEffect
}

/// Whether a request for an audio route (speaker, receiver, a headset) must be sent to the audio session.
///
/// A request used to be dropped whenever it equalled the last value the call stored, but that value is set the moment
/// the user asks, before the session has done anything. When the first attempt had no effect (the session was not
/// active yet, the category was reset by the audio device, an interruption cleared the override) the route stayed
/// where it was, the session reported no change, and every further tap for the same route was dropped for the rest of
/// the call. A request is now skipped only when the session itself reports that route.
func audioOutputRequestDecision<Output: Equatable>(requested: Output, lastRequested: Output?, reported: Output?) -> AudioOutputRequestDecision {
    if let lastRequested, lastRequested == requested, let reported, reported == requested {
        return .skipAlreadyInEffect
    }
    return .apply
}

/// The short-log line for one route request: what was asked, what was stored before, what the session reported.
func audioOutputRequestLogLine(requested: String, lastRequested: String?, reported: String?, decision: AudioOutputRequestDecision, hasSessionControl: Bool, viaCallKit: Bool) -> String {
    let outcome: String
    switch decision {
    case .apply:
        outcome = hasSessionControl ? "applying" : "stored, no session control yet"
    case .skipAlreadyInEffect:
        outcome = "skipped, already the reported route"
    }
    return "audio output request \(requested) (last request \(lastRequested ?? "none"), session reports \(reported ?? "unknown"), \(viaCallKit ? "CallKit" : "direct")): \(outcome)"
}

/// The video call screen puts the sound on the loudspeaker when a video is shown and the route is the receiver, checked
/// every second. When the session does not honour those requests the check must not repeat them for the rest of the
/// call (each one is a session call and a flash of the speaker state on screen), so it gives up after a few attempts
/// and starts over only when the route has changed or the video went away.
struct AutomaticSpeakerEnforcement {
    static let maximumAttempts = 3
    
    private(set) var attempts = 0
    
    mutating func shouldAttempt() -> Bool {
        if self.attempts >= AutomaticSpeakerEnforcement.maximumAttempts {
            return false
        }
        self.attempts += 1
        return true
    }
    
    mutating func reset() {
        self.attempts = 0
    }
}
