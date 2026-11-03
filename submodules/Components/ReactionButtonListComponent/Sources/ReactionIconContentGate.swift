import Foundation

/// Holds work that must wait until a reaction button's animation layer has drawn a frame.
///
/// A reaction sent from the picker lands in the button as the picker's own node, which stands in for
/// the button's layer until it is handed off. The layer loads its first frame asynchronously (from the
/// animation cache, converting the animation when the cache is cold), so handing off before that
/// showed an empty button. Work queued here runs once: when the layer has a frame, or after `timeout`
/// seconds if it never draws one. Main thread only.
public final class ReactionIconContentGate {
    private let schedule: (Double, @escaping () -> Void) -> Void
    private var hasContent: Bool = false
    private var nextId: Int = 0
    private var pending: [(id: Int, action: () -> Void)] = []

    public init(schedule: @escaping (Double, @escaping () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + delay, execute: action)
    }) {
        self.schedule = schedule
    }

    /// Whether the current layer has drawn a frame. Set to false when the layer is replaced.
    public func setHasContent(_ hasContent: Bool) {
        self.hasContent = hasContent
        if hasContent {
            self.runPending()
        }
    }

    /// Runs `action` once the layer has a frame, at once if it already has one, or after `timeout`.
    public func whenContentReady(timeout: Double, _ action: @escaping () -> Void) {
        if self.hasContent {
            action()
            return
        }
        let id = self.nextId
        self.nextId += 1
        self.pending.append((id, action))
        self.schedule(timeout, { [weak self] in
            guard let self, let index = self.pending.firstIndex(where: { $0.id == id }) else {
                return
            }
            let item = self.pending.remove(at: index)
            item.action()
        })
    }

    /// Runs queued work now, whether or not the layer has a frame (the button moved to another reaction).
    public func runPending() {
        let pending = self.pending
        self.pending.removeAll()
        for item in pending {
            item.action()
        }
    }

    /// Drops queued work without running it (the button was reset for another reaction).
    public func cancelAll() {
        self.pending.removeAll()
    }
}
