import Foundation
import CoreGraphics

/// Decoded GIF thumbnails of the panel's tiles, kept so that a tile created while the panel is switching
/// tabs can show its picture at once without decoding anything on the main thread.
///
/// Opening the GIF tab created ~20 `GifVideoLayer`s with `synchronousLoad: true`; each one read the
/// thumbnail resource and drew it on the main thread (92 ms in `GifVideoLayer.init` plus 64 ms of
/// `drawImage` in one trace, 113 and 132 ms hangs). With this cache a tile whose picture was decoded before
/// (an earlier visit of the tab, or the same tile scrolled away and back) is filled synchronously from
/// memory; every other tile loads off the main thread.
public final class GifThumbnailCache {
    public enum LoadPlan: Equatable {
        /// Show the cached picture right away, on the main thread, without decoding.
        case applyCachedNow
        /// Read and draw the picture off the main thread; the tile shows its placeholder until then.
        case loadOffMain
        /// Read and draw on the main thread (the caller asked for it and does not restrict it to the cache).
        case loadOnMain
    }

    /// The decision for one tile. Pure, so it can be tested.
    public static func plan(isCached: Bool, synchronousLoadRequested: Bool, synchronousOnlyFromCache: Bool) -> LoadPlan {
        if !synchronousLoadRequested {
            return .loadOffMain
        }
        if !synchronousOnlyFromCache {
            return .loadOnMain
        }
        return isCached ? .applyCachedNow : .loadOffMain
    }

    public static let shared = GifThumbnailCache()

    private final class Box {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, Box>()

    public init(totalCostLimit: Int = 24 * 1024 * 1024) {
        self.cache.totalCostLimit = totalCostLimit
    }

    public static func key(namespace: Int32, id: Int64, width: Int, height: Int) -> String {
        return "\(namespace)_\(id)_\(width)x\(height)"
    }

    public func image(forKey key: String) -> CGImage? {
        return self.cache.object(forKey: key as NSString)?.image
    }

    public func store(_ image: CGImage, forKey key: String) {
        self.cache.setObject(Box(image: image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    public func removeAll() {
        self.cache.removeAllObjects()
    }
}
