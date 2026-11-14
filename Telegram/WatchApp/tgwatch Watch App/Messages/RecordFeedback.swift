import SwiftUI
import WatchKit

/// Haptics for the voice recorder (WATCH-API-1). The mapping from a state change to a haptic is pure so it can be
/// tested; the view turns it into `SensoryFeedback`.
enum RecordHaptic: Equatable {
    case start
    case stop

    /// The haptic for a recorder state change. Level and elapsed ticks inside `.recording` produce none.
    static func forTransition(from old: RecordState, to new: RecordState) -> RecordHaptic? {
        switch (old, new) {
        case (.recording, .recording):
            return nil
        case (_, .recording):
            return .start
        case (.recording, .stopping), (.recording, .review), (.recording, .idle), (.recording, .failed):
            return .stop
        default:
            return nil
        }
    }

    var feedback: SensoryFeedback {
        switch self {
        case .start: return .start
        case .stop: return .stop
        }
    }
}

enum WatchHaptics {
    /// The note was accepted by the chat.
    @MainActor
    static func sent() {
        WKInterfaceDevice.current().play(.success)
    }
}
