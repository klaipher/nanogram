import Foundation

/// The transaction running on a Postbox queue, readable from any thread (`Postbox.runningTransaction()`) while that
/// queue is busy with it. iOS kills an app that is suspended while a transaction holds the SQLite lock of a database
/// in the shared container (0xdead10cc), so a background-task drain that times out logs what it was still waiting for.
public struct PostboxRunningTransaction {
    public let file: String
    public let line: Int
    /// `CFAbsoluteTimeGetCurrent()` when it began.
    public let startTime: Double

    public init(file: String, line: Int, startTime: Double) {
        self.file = file
        self.line = line
        self.startTime = startTime
    }

    /// The call site, as the transaction logs name it ("ChatListViewState.swift:1078").
    public var site: String {
        return TransactionWriteAttribution.siteName(file: self.file, line: self.line)
    }

    /// "ChatListViewState.swift:1078 for 4300 ms".
    public func logDescription(now: Double) -> String {
        let milliseconds = max(0.0, now - self.startTime) * 1000.0
        return "\(self.site) for \(String(format: "%.0f", milliseconds)) ms"
    }
}
