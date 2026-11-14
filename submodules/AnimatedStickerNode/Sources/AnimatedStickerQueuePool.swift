import Foundation
import SwiftSignalKit

let animatedStickerLegacySharedQueue = Queue()

func animatedStickerQueueIndex(nodeNumber: Int, poolSize: Int) -> Int {
    guard poolSize > 0 else {
        return 0
    }
    let remainder = nodeNumber % poolSize
    return remainder < 0 ? remainder + poolSize : remainder
}

/// Queues the animated sticker nodes run on. With the pool off (default) every node shares one serial
/// default-QoS queue, as upstream. With it on (Debug Settings > "Stickers: parallel queues") nodes created
/// afterwards are spread round-robin over a few serial user-initiated queues; each node still owns one
/// serial queue, so its ordering invariants are unchanged.
public enum AnimatedStickerQueuePool {
    public static let poolSize = 3

    private static let enabledValue = Atomic<Bool>(value: false)
    private static let nodeCounter = Atomic<Int>(value: 0)
    private static let queues: [Queue] = (0 ..< AnimatedStickerQueuePool.poolSize).map { index in
        return Queue(name: "AnimatedStickerNode.pool.\(index)", qos: .userInitiated)
    }

    /// Nodes read it once, when they are created.
    public static var isEnabled: Bool {
        get {
            return self.enabledValue.with { $0 }
        }
        set {
            let _ = self.enabledValue.swap(newValue)
        }
    }

    static func queueForNewNode() -> Queue {
        if !self.isEnabled {
            return animatedStickerLegacySharedQueue
        }
        let number = self.nodeCounter.modify { $0 &+ 1 }
        return self.queues[animatedStickerQueueIndex(nodeNumber: number, poolSize: self.queues.count)]
    }

    static var pooledQueues: [Queue] {
        return self.queues
    }
}
