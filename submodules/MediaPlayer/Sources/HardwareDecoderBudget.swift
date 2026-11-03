import Foundation

public final class HardwareDecoderBudget {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0

    public init(limit: Int) {
        self.limit = limit
    }

    public var activeCount: Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.count
    }

    public func tryAcquire() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.count >= self.limit {
            return false
        }
        self.count += 1
        return true
    }

    public func release() {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        assert(self.count > 0)
        self.count = max(0, self.count - 1)
    }
}

public final class HardwareDecoderSlot {
    private let budget: HardwareDecoderBudget

    private init(budget: HardwareDecoderBudget) {
        self.budget = budget
    }

    public static func acquire(from budget: HardwareDecoderBudget) -> HardwareDecoderSlot? {
        if budget.tryAcquire() {
            return HardwareDecoderSlot(budget: budget)
        }
        return nil
    }

    deinit {
        self.budget.release()
    }
}

public enum GifTileHardwareDecoding {
    public static let minimumLongSide = 320
    public static let budget = HardwareDecoderBudget(limit: 16)

    public static func wantsHardware(width: Int, height: Int, minimumLongSide: Int = GifTileHardwareDecoding.minimumLongSide) -> Bool {
        return max(width, height) >= minimumLongSide
    }

    public static func acquireSlot(width: Int, height: Int, budget: HardwareDecoderBudget = GifTileHardwareDecoding.budget) -> HardwareDecoderSlot? {
        guard self.wantsHardware(width: width, height: height) else {
            return nil
        }
        return HardwareDecoderSlot.acquire(from: budget)
    }

    public static func decoderOptions(width: Int?, height: Int?, hintVP9: Bool, budget: HardwareDecoderBudget = GifTileHardwareDecoding.budget) -> (slot: HardwareDecoderSlot?, skipLoopFilter: Bool) {
        if hintVP9 {
            return (nil, false)
        }
        guard let width = width, let height = height, let slot = self.acquireSlot(width: width, height: height, budget: budget) else {
            return (nil, true)
        }
        return (slot, false)
    }
}
