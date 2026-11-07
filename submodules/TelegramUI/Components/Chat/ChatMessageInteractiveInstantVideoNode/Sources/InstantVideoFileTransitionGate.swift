import Foundation

/// Orders the round video's transitions to and from its transcription (voice-style) layout. Each transition takes a
/// token; a completion that runs after a newer transition has started is stale and must do nothing.
struct InstantVideoFileTransitionGate {
    private var generation: Int = 0

    mutating func begin() -> Int {
        self.generation += 1
        return self.generation
    }

    func isCurrent(_ token: Int) -> Bool {
        return token == self.generation
    }
}
