import Accelerate
import Foundation

/// Level maths for the recorder, on Accelerate (WATCH-SIMD-1). Scalar `for` loops summed squares for every tap buffer
/// and every 20 ms frame of a recording.
enum AudioMeter {
    /// Root mean square of `samples`; 0 for an empty buffer.
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(base, 1, &result, vDSP_Length(samples.count))
        return result
    }

    static func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    /// The meter's visual gain: normal speech should fill the bar.
    static func visualLevel(rms: Float) -> Float {
        min(1, rms * 4)
    }
}

/// FIFO of mono samples consumed by index, so taking a 20 ms frame is a copy of 960 floats rather than an
/// `Array.removeFirst` that shifts everything behind it. Not thread-safe on its own; see `LockedSampleCarry`.
struct SampleCarry {
    private var storage: [Float] = []
    private var head = 0

    /// Samples waiting.
    var count: Int { storage.count - head }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        compactIfNeeded()
        storage.append(contentsOf: samples)
    }

    /// Moves exactly `frame.count` samples into `frame`; false (and nothing consumed) when fewer are waiting.
    mutating func popFrame(into frame: inout [Float]) -> Bool {
        let needed = frame.count
        guard needed > 0, count >= needed else { return false }
        frame.withUnsafeMutableBufferPointer { destination in
            storage.withUnsafeBufferPointer { source in
                guard let to = destination.baseAddress, let from = source.baseAddress else { return }
                to.update(from: from + head, count: needed)
            }
        }
        head += needed
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        }
        return true
    }

    /// Everything still waiting, zero-padded up to `frameSize` (the trailing partial frame); nil when empty.
    mutating func takePaddedRemainder(frameSize: Int) -> [Float]? {
        guard count > 0 else { return nil }
        var frame = [Float](repeating: 0, count: max(frameSize, count))
        for i in 0..<count { frame[i] = storage[head + i] }
        storage.removeAll(keepingCapacity: true)
        head = 0
        return frame
    }

    /// Reclaims the consumed prefix once it is at least half of a sizeable buffer.
    private mutating func compactIfNeeded() {
        if head >= 4_096, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}

/// `SampleCarry` shared between the audio render thread (appends) and the encode queue (pops).
final class LockedSampleCarry: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = SampleCarry()

    func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        carry.append(samples)
        lock.unlock()
    }

    func popFrame(into frame: inout [Float]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return carry.popFrame(into: &frame)
    }

    func takePaddedRemainder(frameSize: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return carry.takePaddedRemainder(frameSize: frameSize)
    }
}

/// Limits meter updates to the main actor to about 20 Hz: one `Task { @MainActor }` per tap buffer (15 to 40 per
/// second) is more wake-ups than a 20 fps meter can show. Used from the audio render thread only.
final class LevelThrottle: @unchecked Sendable {
    private let minimumInterval: TimeInterval
    private var lastEmit: TimeInterval?
    private var peak: Float = 0

    init(minimumInterval: TimeInterval = 0.05) {
        self.minimumInterval = minimumInterval
    }

    /// The level to publish now (the loudest since the last publish), or nil to hold it back. The first call
    /// always publishes.
    func submit(level: Float, now: TimeInterval) -> Float? {
        peak = max(peak, level)
        if let lastEmit, now - lastEmit < minimumInterval { return nil }
        lastEmit = now
        let out = peak
        peak = 0
        return out
    }
}
