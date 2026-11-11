#if os(macOS)
import Foundation
import BroadcastPlayback

public struct GroupCallBroadcastLevels {
    private var pending: [UInt32: (level: Float, voice: Bool)] = [:]

    public init() {
    }

    public mutating func add(_ samples: [BroadcastAudioLevelSample]) {
        for sample in samples {
            if let current = self.pending[sample.ssrc] {
                self.pending[sample.ssrc] = (max(current.level, sample.level), current.voice || sample.voice)
            } else {
                self.pending[sample.ssrc] = (sample.level, sample.voice)
            }
        }
    }

    public mutating func merged(into engineLevels: [(OngoingGroupCallContext.AudioLevelKey, Float, Bool)]) -> [(OngoingGroupCallContext.AudioLevelKey, Float, Bool)] {
        var result = engineLevels
        for ssrc in self.pending.keys.sorted() {
            if let value = self.pending[ssrc] {
                result.append((.source(ssrc), value.level, value.voice))
            }
        }
        self.pending.removeAll()
        return result
    }
}
#endif
