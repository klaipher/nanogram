import Foundation
import SwiftSignalKit

enum BatchVideoDecodePlan {
    static func poolSize(activeProcessors: Int) -> Int {
        return max(2, min(4, activeProcessors - 1))
    }

    static func queueIndex(contextNumber: Int, poolSize: Int) -> Int {
        guard poolSize > 0 else {
            return 0
        }
        let remainder = contextNumber % poolSize
        return remainder < 0 ? remainder + poolSize : remainder
    }
}

/// Tracks which tiles have a decode pass running. Main queue only.
struct BatchVideoDecodeInFlight {
    private var ids = Set<Int>()

    var isEmpty: Bool {
        return self.ids.isEmpty
    }

    func contains(_ id: Int) -> Bool {
        return self.ids.contains(id)
    }

    /// Returns the requests of tiles without a running pass and marks those tiles as running.
    mutating func claim(_ requested: [Int: Int]) -> [Int: Int] {
        var claimed: [Int: Int] = [:]
        for (id, count) in requested where !self.ids.contains(id) {
            self.ids.insert(id)
            claimed[id] = count
        }
        return claimed
    }

    mutating func finish(_ id: Int) {
        self.ids.remove(id)
    }
}

enum BatchVideoDecodeQueues {
    private static let counter = Atomic<Int>(value: 0)
    private static let queues: [Queue] = (0 ..< BatchVideoDecodePlan.poolSize(activeProcessors: ProcessInfo.processInfo.activeProcessorCount)).map { index in
        return Queue(name: "BatchVideoRenderingContext.decode.\(index)", qos: .userInitiated)
    }

    static var count: Int {
        return self.queues.count
    }

    static func nextQueue() -> Queue {
        let number = self.counter.modify { $0 &+ 1 }
        return self.queues[BatchVideoDecodePlan.queueIndex(contextNumber: number, poolSize: self.queues.count)]
    }
}
