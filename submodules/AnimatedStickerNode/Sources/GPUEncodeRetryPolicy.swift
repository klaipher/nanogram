import Foundation

/// When a sticker keeps failing to be DCT-encoded on the GPU (a command buffer that did not complete, a frame the
/// kernel cannot encode), trying the same frame again at every pass costs GPU time each time and gains nothing.
/// After `maxFailuresPerIndex` failures of one frame that frame stays uncached, and after `maxFailuresInTotal`
/// failures the source stops encoding on the GPU. Those frames are then stored by the CPU path of the same cache
/// (LZ4 YUVA; the reader tells the two formats apart by the DCT magic). Not thread safe: use it from the frame
/// source's queue.
struct GPUEncodeRetryPolicy {
    static let maxFailuresPerIndex = 3
    static let maxFailuresInTotal = 8

    private var failuresByIndex: [Int: Int] = [:]
    private(set) var totalFailures = 0

    /// The GPU is no longer used by this source to encode frames.
    var isGPUDisabled: Bool {
        return self.totalFailures >= GPUEncodeRetryPolicy.maxFailuresInTotal
    }

    func shouldAttempt(index: Int) -> Bool {
        if self.isGPUDisabled {
            return false
        }
        return (self.failuresByIndex[index] ?? 0) < GPUEncodeRetryPolicy.maxFailuresPerIndex
    }

    /// Returns true when this failure is the one that disables the GPU for the source (so it is logged once).
    @discardableResult
    mutating func recordFailure(index: Int) -> Bool {
        let wasDisabled = self.isGPUDisabled
        self.failuresByIndex[index, default: 0] += 1
        self.totalFailures += 1
        return !wasDisabled && self.isGPUDisabled
    }

    /// A frame that was encoded forgets its own failures; the total stays.
    mutating func recordSuccess(index: Int) {
        self.failuresByIndex.removeValue(forKey: index)
    }
}
