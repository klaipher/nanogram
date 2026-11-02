import Foundation
import os

/// Signpost intervals around the main-thread hot paths found in device traces: the chat history update
/// (`chatHistoryEntriesForView`) and the composer keystroke. They show in Instruments (os_signpost, subsystem = the
/// bundle id, category "Performance"); when nothing records, an interval costs one enabled check.
public enum PerformanceSignposts {
    public static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "Telegram", category: "Performance")

    @inline(__always)
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = PerformanceSignposts.signposter.beginInterval(name)
        defer {
            PerformanceSignposts.signposter.endInterval(name, state)
        }
        return try body()
    }
}
