import Foundation
import CoreGraphics

/// Decisions of the wallpaper pattern prewarm (the chat wallpaper pattern prewarm), kept free of
/// UIKit so they can be tested on the host.
///
/// The first chat opened after launch used to render the wallpaper pattern on the main thread (about 36 ms, a cache
/// miss in `WallpaperBackgroundNodeImpl.cachedPatternImages`). The prewarm renders the same image in the background
/// while the chat list is idle and stores it under the same key, so the chat finds it.
enum WallpaperPatternPrewarmPlan {
    /// The size a full-screen chat lays its background out at on an iPhone: the whole screen, in portrait. `nil` where
    /// the chat size is not known ahead (iPad split view, windows, an empty or invalid screen).
    static func chatBackgroundSize(screenSize: CGSize, isPhone: Bool) -> CGSize? {
        guard isPhone, screenSize.width.isFinite, screenSize.height.isFinite, screenSize.width > 0.0, screenSize.height > 0.0 else {
            return nil
        }
        return CGSize(width: min(screenSize.width, screenSize.height), height: max(screenSize.width, screenSize.height))
    }

    /// A render is worth starting only when the pattern is not stored yet.
    static func shouldRender(isAlreadyCached: Bool) -> Bool {
        return !isAlreadyCached
    }
}

/// Tells a finished background render whether its result is still wanted. Every new request, cancel and memory warning
/// starts a new epoch, so a render that was in flight when the memory was needed is dropped instead of stored.
struct WallpaperPatternPrewarmEpoch {
    private(set) var current: UInt64 = 0

    /// A new request: supersedes the one in flight.
    mutating func begin() -> UInt64 {
        self.current &+= 1
        return self.current
    }

    /// Cancel or memory warning: nothing in flight is wanted any more.
    mutating func invalidate() {
        self.current &+= 1
    }

    func isCurrent(_ token: UInt64) -> Bool {
        return self.current == token
    }
}
