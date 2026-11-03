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
