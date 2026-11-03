import Foundation

/// Holds work that must wait until a reaction button's animation layer has drawn a frame.
///
/// A reaction sent from the picker lands in the button as the picker's own node, which stands in for
/// the button's layer until it is handed off. The layer loads its first frame asynchronously (from the
/// animation cache, converting the animation when the cache is cold), so handing off before that
/// showed an empty button. Work queued here runs once, when the layer has a frame, or at once when the
/// button moves to another reaction (`runPending`). There is no timeout: one could only reveal a layer
/// that still has nothing to show. A reset drops the work (`cancelAll`), and the button's subviews, the
/// stand-in included, go with it, so a stand-in never outlives its button. Main thread only.
public final class ReactionIconContentGate {
    public private(set) var hasContent: Bool = false
    private var pending: [() -> Void] = []

    public init() {
    }

    /// Whether work is waiting for the layer's first frame.
    public var hasPendingWork: Bool {
        return !self.pending.isEmpty
    }

    /// Whether the current layer has drawn a frame. Set to false when the layer is replaced.
    public func setHasContent(_ hasContent: Bool) {
        self.hasContent = hasContent
        if hasContent {
            self.runPending()
        }
    }

    /// Runs `action` once the layer has a frame, at once if it already has one.
    public func whenContentReady(_ action: @escaping () -> Void) {
        if self.hasContent {
            action()
            return
        }
        self.pending.append(action)
    }

    /// Runs queued work now, whether or not the layer has a frame (the button moved to another reaction).
    public func runPending() {
        let pending = self.pending
        self.pending.removeAll()
        for action in pending {
            action()
        }
    }

    /// Drops queued work without running it (the button was reset for another reaction).
    public func cancelAll() {
        self.pending.removeAll()
    }
}
