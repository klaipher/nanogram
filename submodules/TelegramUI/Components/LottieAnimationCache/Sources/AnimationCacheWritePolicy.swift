import Foundation
import UIKit
import SwiftSignalKit
import AnimationCache

/// Decisions about what an animated grid cell writes to the animation cache, and when. Pure, so it can be tested
/// without a cache or a screen.
///
/// A gift in a store or profile grid used to be cached at four times its size in points (upstream passes twice the
/// size as the point size, and the cache renders at 2x), which is more pixels than the cell ever shows, and every cell
/// that came into view started a full conversion, including the ones a fling carried past in a fraction of a second.
public enum AnimationCacheWritePolicy {
    /// Where an animation is shown.
    public enum Surface: Equatable {
        /// One of many cells in a scrolling grid: it may be scrolled past before it settles.
        case scrollingGrid
        /// A single large item the user opened: it starts at once.
        case single
    }

    /// How long a grid cell must have been alive before its full conversion starts. A cell that is already in the
    /// cache never waits (the delay applies only when the cache has to convert); its first frame is not delayed.
    public static let scrollingGridStartDelay: Double = 0.35

    public static func startDelay(for surface: Surface) -> Double {
        switch surface {
        case .scrollingGrid:
            return AnimationCacheWritePolicy.scrollingGridStartDelay
        case .single:
            return 0.0
        }
    }

    /// The pixel size to cache an animation at: the size the surface asks for, but never more pixels than the item
    /// is displayed with on this screen. `displayPointSize` is nil for a surface that keeps the requested size.
    public static func pixelSize(requested: CGSize, displayPointSize: CGSize?, screenScale: CGFloat) -> CGSize {
        guard let displayPointSize, displayPointSize.width > 0.0, displayPointSize.height > 0.0, screenScale > 0.0 else {
            return requested
        }
        return CGSize(
            width: min(requested.width, ceil(displayPointSize.width * screenScale)),
            height: min(requested.height, ceil(displayPointSize.height * screenScale))
        )
    }

    /// `fetch` that starts after `delay` and does nothing if it is disposed before. The cache calls the fetch only
    /// when it has to convert, so a cache hit never waits. A delay of zero or less returns `fetch` itself.
    public static func deferred(delay: Double, queue: Queue = Queue.concurrentDefaultQueue(), fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> (AnimationCacheFetchOptions) -> Disposable {
        if delay <= 0.0 {
            return fetch
        }
        return { options in
            let disposable = MetaDisposable()
            let isCancelled = Atomic<Bool>(value: false)
            queue.after(delay, {
                if isCancelled.with({ $0 }) {
                    return
                }
                disposable.set(fetch(options))
            })
            return ActionDisposable {
                let _ = isCancelled.swap(true)
                disposable.dispose()
            }
        }
    }
}
