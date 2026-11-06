import Foundation

/// Setup of a screen that is not needed for its first frame. With `isEnabled` false (the default) `run` executes the
/// work at once, in the caller's order, so the code path is exactly the one without this type. With it true the work is
/// kept and executed in submission order by `flush()` (the screen calls that after its first appearance); work submitted
/// after the flush runs at once. `flush()` executes everything at most once.
///
/// Main thread only. The work must not depend on running before the first frame: that is what the caller has to check
/// for every item it submits.
public final class DeferredSetup {
    public let isEnabled: Bool
    public private(set) var isFlushed: Bool = false
    private var pending: [(name: StaticString, work: () -> Void)] = []

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Number of items waiting for `flush()`.
    public var pendingCount: Int {
        return self.pending.count
    }

    /// Runs `work` now (disabled, or already flushed) or keeps it for `flush()`. `name` is the signpost interval
    /// (`PerformanceSignpostName.chatInitDeferrable`) around the work, wherever it runs.
    public func run(_ name: StaticString = PerformanceSignpostName.chatInitDeferrable, _ work: @escaping () -> Void) {
        if !self.isEnabled || self.isFlushed {
            NanogramSignposts.interval(name, work)
        } else {
            self.pending.append((name, work))
        }
    }

    /// Executes the kept work in submission order. Work submitted by the work itself runs at once (after the flag is set).
    public func flush() {
        if self.isFlushed {
            return
        }
        self.isFlushed = true
        let items = self.pending
        self.pending = []
        for item in items {
            NanogramSignposts.interval(item.name, item.work)
        }
    }

    /// Drops the kept work (the screen went away before it appeared).
    public func discard() {
        self.isFlushed = true
        self.pending = []
    }
}
