import Foundation

/// Counts how often `MediaBoxFileManager` opened a file, and how often that was a file it had opened before and
/// evicted (a re-open: an `open` and a `close` that a larger table would have saved). It says when to log: at most
/// once a minute, and only when the counters moved.
struct MediaBoxFileManagerStats: Equatable {
    static let logInterval: Double = 60.0

    private(set) var opened: Int = 0
    private(set) var reopened: Int = 0
    private var loggedOpened: Int = 0
    private var loggedReopened: Int = 0
    private var lastLogTime: Double?

    mutating func noteOpen(isReopen: Bool) {
        self.opened += 1
        if isReopen {
            self.reopened += 1
        }
    }

    /// The text to log now, if a minute has passed since the last line and something was opened since then.
    /// `currentlyOpen` is the number of handles in the table at this moment.
    mutating func takeLogLine(now: Double, currentlyOpen: Int) -> String? {
        if self.opened == self.loggedOpened && self.reopened == self.loggedReopened {
            return nil
        }
        if let lastLogTime = self.lastLogTime {
            let elapsed = now - lastLogTime
            // A clock that went backwards must not silence the log for good.
            if elapsed >= 0.0 && elapsed < MediaBoxFileManagerStats.logInterval {
                return nil
            }
        }
        let opened = self.opened - self.loggedOpened
        let reopened = self.reopened - self.loggedReopened
        self.lastLogTime = now
        self.loggedOpened = self.opened
        self.loggedReopened = self.reopened
        return "MediaBoxFileManager: opened=\(opened) reopened=\(reopened) (this minute), total opened=\(self.opened) reopened=\(self.reopened), open now=\(currentlyOpen)"
    }
}
