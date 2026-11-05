import Foundation

/// Decides when the player has to wake an `FFMpegLookahead` thread. The player reports its position about ten times
/// a second. The lookahead thread only has work when the readable range has fallen noticeably behind the position,
/// so a full buffer is left alone: the position is stored for the thread to read and no wake-up is sent. While a
/// wake-up is already queued no second one is sent either, because the thread reads the newest position when it runs.
final class FFMpegLookaheadWakeGate: @unchecked Sendable {
    static let maxRefillMargin: Double = 2.0

    /// The buffer is topped up once it holds less than the lookahead minus this margin.
    static func refillMargin(lookaheadDuration: Double) -> Double {
        return min(FFMpegLookaheadWakeGate.maxRefillMargin, max(0.0, lookaheadDuration) * 0.25)
    }

    static func needsRefill(position: Double, seekTo: Double, lookaheadDuration: Double, readableTo: Double) -> Bool {
        let target = max(seekTo, position) + lookaheadDuration
        return readableTo < target - FFMpegLookaheadWakeGate.refillMargin(lookaheadDuration: lookaheadDuration)
    }

    private let lock = NSLock()
    private var readableTo: Double?
    private var isEnded = false
    private var wakePending = false

    /// Called by the lookahead thread after each read pass. `readableTo` is the time every stream can be read up to,
    /// or nil while a stream has not produced a packet yet.
    func noteProgress(readableTo: Double?, isEnded: Bool) {
        self.lock.lock()
        self.readableTo = readableTo
        self.isEnded = isEnded
        self.lock.unlock()
    }

    /// Called by the lookahead thread when it starts handling a wake-up, before it reads the newest position.
    func beginWake() {
        self.lock.lock()
        self.wakePending = false
        self.lock.unlock()
    }

    /// Called on each position update. True when the caller must send a wake-up (and has then one queued).
    func shouldWake(position: Double, seekTo: Double, lookaheadDuration: Double) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.wakePending || self.isEnded {
            return false
        }
        if let readableTo = self.readableTo, !FFMpegLookaheadWakeGate.needsRefill(position: position, seekTo: seekTo, lookaheadDuration: lookaheadDuration, readableTo: readableTo) {
            return false
        }
        self.wakePending = true
        return true
    }
}
