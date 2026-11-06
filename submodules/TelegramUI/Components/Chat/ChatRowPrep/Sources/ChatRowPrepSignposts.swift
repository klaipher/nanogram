import Foundation
import SwiftSignalKit

/// Point events in category `Performance`, so a trace shows whether the two switches do anything. No metadata. They are
/// only emitted while the matching switch is on.
public enum ChatRowPrepSignposts {
    /// A row was built from a prepared result.
    public static func prefetchHit() {
        NanogramSignposts.event("chatRowPrefetchHit")
    }

    /// The list asked for a row and nothing usable was prepared (it was laid out synchronously).
    public static func prefetchMiss() {
        NanogramSignposts.event("chatRowPrefetchMiss")
    }

    /// A pooled row view was handed to a new row.
    public static func poolReuse() {
        NanogramSignposts.event("chatRowPoolReuse")
    }

    /// A row needed a view and the pool had none of the right type.
    public static func poolMiss() {
        NanogramSignposts.event("chatRowPoolMiss")
    }

    /// The background part of one row preparation. Interval.
    public static let prefetchCompute: StaticString = "chatRowPrefetchCompute"
}
