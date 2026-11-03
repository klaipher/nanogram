import Foundation
import UniversalMediaPlayer

// An incoming voice message nobody has listened to draws its whole waveform in the highlight colour,
// which is also the colour of the played part. The bubble drops the highlight only when it lays itself
// out again after the message is marked listened; until then the progress of a playback that has
// started would be invisible (the waveform is "all filled"). So the waveform stops highlighting itself
// as soon as it sees its message play, and starts again only for a new highlight request.
public struct AudioWaveformUnplayedHighlight: Equatable {
    public private(set) var requested: Bool = false
    public private(set) var hasPlayed: Bool = false

    public init() {
    }

    public var isDrawn: Bool {
        return self.requested && !self.hasPlayed
    }

    // `contentChanged`: the waveform now shows another message (its samples changed).
    public mutating func update(requested: Bool, contentChanged: Bool) {
        if contentChanged || (requested && !self.requested) {
            self.hasPlayed = false
        }
        self.requested = requested
    }

    public mutating func update(status: MediaPlayerPlaybackStatus) {
        if case .playing = status {
            self.hasPlayed = true
        }
    }
}
