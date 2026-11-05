import Foundation

/// Activities whose CPU, GPU and disk use the daily MetricKit report should be split by. The report then says how much
/// of a day's cost fell into sticker playback, video playback, calls or round-video recording. The intervals stay in
/// MetricKit on the device; nothing is sent anywhere.
public enum MetricActivity: CaseIterable, Sendable {
    case stickerPlayback
    case videoPlayback
    case call
    case roundVideoRecording
}

/// Keeps one open interval per activity while at least one holder is active: ten playing stickers are one interval.
/// A holder ends its part by releasing the token or by calling `end()`; the last one closes the interval.
public final class ActivityIntervalCounter: @unchecked Sendable {
    public final class Token: @unchecked Sendable {
        private let counter: ActivityIntervalCounter
        private let activity: MetricActivity
        private let lock = NSLock()
        private var isActive = true

        fileprivate init(counter: ActivityIntervalCounter, activity: MetricActivity) {
            self.counter = counter
            self.activity = activity
        }

        deinit {
            self.end()
        }

        public func end() {
            self.lock.lock()
            let wasActive = self.isActive
            self.isActive = false
            self.lock.unlock()
            if wasActive {
                self.counter.release(self.activity)
            }
        }
    }

    private let lock = NSLock()
    private let onChange: (MetricActivity, Bool) -> Void
    private var counts: [MetricActivity: Int] = [:]

    /// `onChange` is called with `true` when the first holder of an activity starts and `false` when the last one ends.
    public init(onChange: @escaping (MetricActivity, Bool) -> Void) {
        self.onChange = onChange
    }

    public func begin(_ activity: MetricActivity) -> Token {
        self.lock.lock()
        let count = (self.counts[activity] ?? 0) + 1
        self.counts[activity] = count
        if count == 1 {
            self.onChange(activity, true)
        }
        self.lock.unlock()
        return Token(counter: self, activity: activity)
    }

    public func isActive(_ activity: MetricActivity) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return (self.counts[activity] ?? 0) > 0
    }

    fileprivate func release(_ activity: MetricActivity) {
        self.lock.lock()
        let count = max(0, (self.counts[activity] ?? 0) - 1)
        self.counts[activity] = count == 0 ? nil : count
        if count == 0 {
            self.onChange(activity, false)
        }
        self.lock.unlock()
    }
}
