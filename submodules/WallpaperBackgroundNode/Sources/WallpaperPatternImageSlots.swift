import Foundation

/// Rendered wallpaper patterns kept across background nodes. A miss costs about 40 ms of CG work,
/// on the main thread for chats and previews.
/// One slot belongs to the nodes with a shared animation phase (full chats), as before. The other
/// takes everything else (long-press chat previews, settings previews), so those can hit too
/// without evicting the chat's pattern.
struct WallpaperPatternImageSlots<Value> {
    private var shared: Value?
    private var nonShared: Value?

    init() {
    }

    var count: Int {
        return (self.shared == nil ? 0 : 1) + (self.nonShared == nil ? 0 : 1)
    }

    func first(where predicate: (Value) -> Bool) -> Value? {
        if let shared = self.shared, predicate(shared) {
            return shared
        }
        if let nonShared = self.nonShared, predicate(nonShared) {
            return nonShared
        }
        return nil
    }

    mutating func store(_ value: Value, isShared: Bool) {
        if isShared {
            self.shared = value
        } else {
            self.nonShared = value
        }
    }

    /// On background: keep what full chats use, drop the rest.
    mutating func removeNonShared() {
        self.nonShared = nil
    }

    /// On memory warning.
    mutating func removeAll() {
        self.shared = nil
        self.nonShared = nil
    }
}
