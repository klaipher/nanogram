import Foundation

// Pure scroll-speed bookkeeping for the photo grid: is the user flinging fast enough that thumbnails would be off screen
// again before they arrive?
public struct ScrollVelocityEstimator {
    // Points per second at which a fling starts / stops counting. The gap is the hysteresis, so a speed that hovers
    // around one number does not flip the state on every tick (a grid row is about 100 pt, so 2400 is ~24 rows/s).
    public static let flingStartSpeed: Double = 2400.0
    public static let flingEndSpeed: Double = 1200.0
    // A sample older than this says nothing about the current speed: the scroll view has stopped delivering offsets.
    public static let staleAfter: Double = 0.12
    // Samples closer together than this are merged into the next one; below it the division is noise.
    private static let minimumInterval: Double = 0.004

    private var lastOffset: Double?
    private var lastTime: Double = 0.0
    private var smoothedSpeed: Double = 0.0
    private var flinging: Bool = false

    public init() {
    }

    // Feed the scroll offset (points) and a monotonic time (seconds).
    public mutating func note(offset: Double, time: Double) {
        guard offset.isFinite, time.isFinite else {
            return
        }
        guard let lastOffset = self.lastOffset, time >= self.lastTime else {
            self.lastOffset = offset
            self.lastTime = time
            return
        }
        let interval = time - self.lastTime
        if interval < ScrollVelocityEstimator.minimumInterval {
            return
        }
        let instantaneous = abs(offset - lastOffset) / interval
        // Exponential smoothing, so one large jump (a programmatic scroll-to) does not count as a fling by itself.
        self.smoothedSpeed = self.smoothedSpeed * 0.5 + instantaneous * 0.5
        self.lastOffset = offset
        self.lastTime = time
        self.updateState()
    }

    // Forgets the fling (the scroll view was touched or came to rest).
    public mutating func reset() {
        self.lastOffset = nil
        self.smoothedSpeed = 0.0
        self.flinging = false
    }

    // The smoothed speed at `time`; zero when the last sample is stale.
    public func speed(at time: Double) -> Double {
        if self.lastOffset == nil || time - self.lastTime > ScrollVelocityEstimator.staleAfter {
            return 0.0
        }
        return self.smoothedSpeed
    }

    public mutating func isFlinging(at time: Double) -> Bool {
        if self.flinging && self.speed(at: time) < ScrollVelocityEstimator.flingEndSpeed {
            self.flinging = false
            self.smoothedSpeed = 0.0
        }
        return self.flinging
    }

    private mutating func updateState() {
        if self.flinging {
            if self.smoothedSpeed < ScrollVelocityEstimator.flingEndSpeed {
                self.flinging = false
            }
        } else if self.smoothedSpeed >= ScrollVelocityEstimator.flingStartSpeed {
            self.flinging = true
        }
    }
}
