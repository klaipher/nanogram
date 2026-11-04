import Foundation

/// Which tiles of a group call's video grid the app asks the server for.
///
/// Up to `unlimitedTileCount` tiles every tile is requested, as it always was. Above that only
/// the tiles on screen plus a margin of `prefetchTiles` tiles around them, and the tile that is
/// expanded, are requested. Tiles are indices into the grid's participant list.
enum VideoRequestPolicy {
    static let unlimitedTileCount = 6
    static let prefetchTiles = 2

    /// `visible` is the grid's visible index range; `maxIndex < minIndex` means nothing is on
    /// screen, `nil` that the layout is not known yet. Either asks for the leading tiles, which is
    /// where a grid starts out.
    static func requestedTileIndices(tileCount: Int, visible: (minIndex: Int, maxIndex: Int)?, forced: Set<Int>) -> Set<Int> {
        if tileCount <= 0 {
            return []
        }
        if tileCount <= self.unlimitedTileCount {
            return Set(0 ..< tileCount)
        }

        var result = Set<Int>()
        if let visible, visible.maxIndex >= visible.minIndex {
            let lower = max(0, visible.minIndex - self.prefetchTiles)
            let upper = min(tileCount - 1, visible.maxIndex + self.prefetchTiles)
            if lower <= upper {
                for index in lower ... upper {
                    result.insert(index)
                }
            }
        }
        if result.isEmpty {
            for index in 0 ..< self.unlimitedTileCount {
                result.insert(index)
            }
        }
        for index in forced where index >= 0 && index < tileCount {
            result.insert(index)
        }
        return result
    }
}

/// Keeps a tile requested for a while after it stops being wanted. The engine destroys the receive stream and
/// decoder of a video that drops out of the request and builds it again (with a wait for a keyframe) when it
/// returns, so a fast scroll over a big grid must not flip tiles in and out. Additions are immediate.
struct VideoRequestRetention<Key: Hashable> {
    static var removalDelay: Double {
        return 2.5
    }

    /// Keys that were wanted and are not any more, with the time they were first seen missing.
    private var absentSince: [Key: Double] = [:]
    private var known = Set<Key>()

    init() {
    }

    /// `wanted` is what the policy asks for now; the result is that plus whatever has been missing from
    /// the policy for less than `removalDelay`.
    mutating func requested(wanted: Set<Key>, now: Double) -> Set<Key> {
        var result = wanted
        for key in wanted {
            self.absentSince.removeValue(forKey: key)
            self.known.insert(key)
        }
        for key in self.known where !wanted.contains(key) {
            let since = self.absentSince[key] ?? now
            if now - since < VideoRequestRetention.removalDelay {
                self.absentSince[key] = since
                result.insert(key)
            } else {
                self.absentSince.removeValue(forKey: key)
                self.known.remove(key)
            }
        }
        return result
    }

    /// When the oldest retained key expires, so the caller can look again without waiting for a scroll.
    /// `nil` when nothing is only being retained.
    func nextExpiry() -> Double? {
        return self.absentSince.values.min().map { $0 + VideoRequestRetention.removalDelay }
    }

    mutating func reset() {
        self.absentSince.removeAll()
        self.known.removeAll()
    }
}
