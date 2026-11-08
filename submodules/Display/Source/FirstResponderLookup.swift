import Foundation
import UIKit

/// Finds the first responder inside a view tree. The depth-first search visits every subview of the window and ran on
/// every keyboard notification and every touch-down while the keyboard is up. The
/// responder rarely changes between calls, so the last one found is kept (weakly) and returned again while it is still
/// the first responder and still inside the searched root; otherwise the full search runs and refreshes the cache.
/// Main thread only.
final class FirstResponderLookup {
    static let shared = FirstResponderLookup()

    private weak var cachedResponder: UIView?
    /// Number of full tree searches run; read by the tests.
    private(set) var fullSearchCount = 0

    init() {
    }

    /// Same result as `fullSearch(root, accessoryHeight)`: the first responder under `root` (or `root` itself) and the
    /// height of the nearest `WindowInputAccessoryHeightProvider` among its ancestors from `root` down (the deepest one
    /// wins), or `accessoryHeight` if there is none.
    func find(in root: UIView, accessoryHeight: CGFloat? = nil) -> (UIView?, CGFloat?) {
        if let cached = self.cachedResponder, cached.isFirstResponder, cached.isDescendant(of: root) {
            if cached === root {
                return (cached, accessoryHeight)
            }
            // The height comes from the ancestors, which can have changed since the responder was found: recompute it.
            var height = accessoryHeight
            var ancestor = cached.superview
            while let current = ancestor {
                if let provider = current as? WindowInputAccessoryHeightProvider {
                    height = provider.getWindowInputAccessoryHeight()
                    break
                }
                if current === root {
                    break
                }
                ancestor = current.superview
            }
            return (cached, height)
        }
        self.fullSearchCount += 1
        let result = FirstResponderLookup.fullSearch(root, accessoryHeight)
        if let view = result.0 {
            self.cachedResponder = view
        }
        return result
    }

    func findView(in root: UIView) -> UIView? {
        return self.find(in: root).0
    }

    /// The uncached depth-first search (the reference behaviour).
    static func fullSearch(_ view: UIView, _ accessoryHeight: CGFloat?) -> (UIView?, CGFloat?) {
        if view.isFirstResponder {
            return (view, accessoryHeight)
        } else {
            var updatedAccessoryHeight = accessoryHeight
            if let view = view as? WindowInputAccessoryHeightProvider {
                updatedAccessoryHeight = view.getWindowInputAccessoryHeight()
            }
            for subview in view.subviews {
                let (result, resultHeight) = fullSearch(subview, updatedAccessoryHeight)
                if let result = result {
                    return (result, resultHeight)
                }
            }
            return (nil, nil)
        }
    }
}
