import Foundation

/// Decides when a playing video stores its resume position. Each store rewrites the whole message in the database and
/// updates every view that shows it, so a steadily playing video stores at most every `periodicInterval` seconds and
/// never stores a value it already stored. A pause, a seek or a rate change stores at once, and a forced store (the
/// item is closed or scrolled away) always goes through, so the position the user leaves at is the one kept.
public struct MediaPlaybackPositionStoreThrottle {
    public struct Entry: Equatable {
        public var timestamp: Double?
        public var rate: Double

        public init(timestamp: Double?, rate: Double) {
            self.timestamp = timestamp
            self.rate = rate
        }
    }

    public static let periodicInterval: Double = 5.0

    public private(set) var lastStored: Entry?
    private var lastStoreTime: Double?
    private var lastSeekId: Int?

    public init() {
    }

    /// Returns whether `entry` should be stored now, and if so records it as stored. `now` is a monotonic clock in
    /// seconds (e.g. `CACurrentMediaTime()`); `seekId` is `MediaPlayerStatus.seekId`, which changes on every seek.
    public mutating func shouldStore(_ entry: Entry, seekId: Int, isPlaying: Bool, now: Double, force: Bool = false) -> Bool {
        let didSeek = self.lastSeekId.flatMap { $0 != seekId } ?? false
        self.lastSeekId = seekId

        let store: Bool
        if force {
            store = true
        } else if let lastStored = self.lastStored, let lastStoreTime = self.lastStoreTime {
            if lastStored == entry {
                store = false
            } else if lastStored.rate != entry.rate || didSeek || !isPlaying {
                store = true
            } else {
                // A clock that went backwards counts as an elapsed interval.
                let elapsed = now - lastStoreTime
                store = elapsed >= MediaPlaybackPositionStoreThrottle.periodicInterval || elapsed < 0.0
            }
        } else {
            store = true
        }

        if store {
            self.lastStored = entry
            self.lastStoreTime = now
        }
        return store
    }
}
