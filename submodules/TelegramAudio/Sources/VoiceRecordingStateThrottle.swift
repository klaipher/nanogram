import Foundation

// How often the voice recorder publishes `.recording(duration:)`. The encoder takes a packet every
// 20 ms; the recording-time label (which shows hundredths) and the stories panel redraw on each
// state, so the state is published at most every 1/30 s instead of for every packet.
public struct VoiceRecordingStateThrottle {
    public static let minimumInterval: Double = 1.0 / 30.0

    private var lastTimestamp: Double?

    public init() {
    }

    // True when a state for `timestamp` should be published; records it as the last one.
    public mutating func shouldPublish(at timestamp: Double) -> Bool {
        if let lastTimestamp = self.lastTimestamp, timestamp < lastTimestamp + VoiceRecordingStateThrottle.minimumInterval {
            return false
        }
        self.lastTimestamp = timestamp
        return true
    }
}
