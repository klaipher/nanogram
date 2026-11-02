import Foundation

// A process-wide cap on live hardware decoders of one kind. VideoToolbox session limits are not
// documented, so callers that can open many at once (a grid of GIF tiles) take a slot first and
// decode in software when none is left.
public final class HardwareDecoderBudget: @unchecked Sendable {
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
