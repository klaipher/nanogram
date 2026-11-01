import Foundation

/// `(timestamp + offset)` rounded toward zero to a multiple of `granularity`: the local-day
/// key the chat date headers and the call list group by. Message dates come from the server,
/// so this is computed in 64 bits and clamped to Int32 instead of trapping near Int32.min/max.
public func timestampRoundedToGranularity(_ timestamp: Int32, offset: Int32, granularity: Int32) -> Int32 {
    if granularity <= 0 {
        return timestamp
    }
    let shifted = Int64(timestamp) + Int64(offset)
    let step = Int64(granularity)
    return Int32(clamping: (shifted / step) * step)
}
