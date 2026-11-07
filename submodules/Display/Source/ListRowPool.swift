import Foundation

/// A small bounded pool of list row nodes that left a list and may be reused for the next rows. Main thread only.
///
/// A node is offered when it leaves the list, but it may still come back in the same list update, so it is not usable
/// at once: `schedule` runs a coalesced batch later and `prepare` decides (and resets the node) before the node is
/// moved to the ready list.
public final class ListRowPool<Node: AnyObject> {
    private let capacity: Int
    private let schedule: (@escaping () -> Void) -> Void
    private let prepare: (Node) -> Bool
    
    private var generation: Int = 0
    private var isBatchScheduled: Bool = false
    private var pending: [Node] = []
    private var preparingCount: Int = 0
    private var ready: [Node] = []
    
    public init(capacity: Int, schedule: @escaping (@escaping () -> Void) -> Void, prepare: @escaping (Node) -> Bool) {
        self.capacity = max(0, capacity)
        self.schedule = schedule
        self.prepare = prepare
    }
    
    public var readyCount: Int {
        return self.ready.count
    }
    
    public var pendingCount: Int {
        return self.pending.count
    }
    
    /// Queues `node` (identity-deduplicated). One coalesced `schedule` per batch runs `prepare` on each pending node
    /// (dropped on false or after `drain`), then moves it to ready. Pending + ready never exceed `capacity`: the
    /// oldest ready node is evicted first; when all are pending the new node is ignored.
    public func offer(_ node: Node) {
        if self.capacity == 0 {
            return
        }
        if self.pending.contains(where: { $0 === node }) || self.ready.contains(where: { $0 === node }) {
            return
        }
        if self.pending.count + self.preparingCount + self.ready.count >= self.capacity {
            if self.ready.isEmpty {
                return
            }
            self.ready.removeFirst()
        }
        self.pending.append(node)
        if !self.isBatchScheduled {
            self.isBatchScheduled = true
            let generation = self.generation
            self.schedule { [weak self] in
                self?.runBatch(generation: generation)
            }
        }
    }
    
    private func runBatch(generation: Int) {
        if generation != self.generation {
            return
        }
        self.isBatchScheduled = false
        let batch = self.pending
        self.pending = []
        self.preparingCount = batch.count
        for node in batch {
            self.preparingCount -= 1
            if generation != self.generation {
                break
            }
            if self.prepare(node) && generation == self.generation {
                self.ready.append(node)
            }
        }
        self.preparingCount = 0
    }
    
    /// Most recently prepared ready node that passes `isUsable`; unusable ones met on the way are dropped.
    public func take(where isUsable: (Node) -> Bool) -> Node? {
        while let node = self.ready.popLast() {
            if isUsable(node) {
                return node
            }
        }
        return nil
    }
    
    /// Drops every node. Prepares that are queued but have not run yet drop their nodes.
    public func drain() {
        self.generation += 1
        self.isBatchScheduled = false
        self.pending = []
        self.ready = []
    }
}
