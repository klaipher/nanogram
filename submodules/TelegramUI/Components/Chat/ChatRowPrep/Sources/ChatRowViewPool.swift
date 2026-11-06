import Foundation

/// A bounded pool of row views by kind (the concrete item view type). A view is reset when it is recycled, not when it
/// is handed out, so everything it holds (subscriptions, media) is released as soon as the row leaves.
///
/// Main thread only.
public final class ChatRowViewPool<View: AnyObject, Kind: Hashable> {
    public struct Limits {
        public var perKind: Int
        public var total: Int

        public init(perKind: Int = 4, total: Int = 8) {
            self.perKind = perKind
            self.total = total
        }
    }

    private struct Slot {
        let kind: Kind
        let view: View
    }

    public let limits: Limits
    /// Puts the view into its fresh state. Returns false when it cannot be reused (it is then not pooled).
    private let reset: (View) -> Bool
    /// Called for every view that leaves the pool without being handed out: refused by `reset`, evicted by a cap, or drained.
    public var onDiscard: ((View) -> Void)?
    /// Oldest first.
    private var slots: [Slot] = []

    public private(set) var reuseCount: Int = 0
    public private(set) var missCount: Int = 0

    public init(limits: Limits = Limits(), reset: @escaping (View) -> Bool) {
        self.limits = limits
        self.reset = reset
    }

    public var count: Int {
        return self.slots.count
    }

    public func count(of kind: Kind) -> Int {
        return self.slots.filter { $0.kind == kind }.count
    }

    /// Resets `view` and keeps it for `kind`. Returns false when it was not kept (reset refused it).
    @discardableResult
    public func recycle(_ view: View, kind: Kind) -> Bool {
        guard self.reset(view) else {
            self.onDiscard?(view)
            return false
        }
        while self.count(of: kind) >= self.limits.perKind, let index = self.slots.firstIndex(where: { $0.kind == kind }) {
            self.discard(at: index)
        }
        while self.slots.count >= self.limits.total, !self.slots.isEmpty {
            self.discard(at: 0)
        }
        if self.limits.perKind <= 0 || self.limits.total <= 0 {
            self.onDiscard?(view)
            return false
        }
        self.slots.append(Slot(kind: kind, view: view))
        return true
    }

    /// The most recently recycled view of `kind`.
    public func obtain(kind: Kind) -> View? {
        if let index = self.slots.lastIndex(where: { $0.kind == kind }) {
            self.reuseCount += 1
            return self.slots.remove(at: index).view
        }
        self.missCount += 1
        return nil
    }

    public func drain() {
        let all = self.slots
        self.slots.removeAll()
        for slot in all {
            self.onDiscard?(slot.view)
        }
    }

    private func discard(at index: Int) {
        let slot = self.slots.remove(at: index)
        self.onDiscard?(slot.view)
    }
}
