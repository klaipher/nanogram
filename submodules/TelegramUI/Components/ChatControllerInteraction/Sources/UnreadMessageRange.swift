import Foundation

// The ids of incoming messages read while the chat is open, for the one-time effects of unread messages.
// `current` is the range so far, `previousMaxIncomingReadId` the read mark before this update (nil when the chat had
// none) and `maxIncomingReadId` the new one. Returns the range to keep.
//
// The read mark comes from the server and can be Int32.max, so nothing here may overflow or build an inverted range.
public func updatedUnreadMessageRange(current: Range<Int32>?, previousMaxIncomingReadId: Int32?, maxIncomingReadId: Int32) -> Range<Int32>? {
    let upperBound = unreadMessageRangeSuccessor(maxIncomingReadId)
    if let current {
        if current.upperBound < upperBound {
            return current.lowerBound ..< upperBound
        }
        return current
    }
    if let previousMaxIncomingReadId {
        let lowerBound = unreadMessageRangeSuccessor(previousMaxIncomingReadId)
        if lowerBound > upperBound {
            return nil
        }
        return lowerBound ..< upperBound
    }
    // Everything after the read mark.
    let endOfIds = Int32.max - 1
    return min(upperBound, endOfIds) ..< endOfIds
}

// The id after `id`, or Int32.max when there is none.
private func unreadMessageRangeSuccessor(_ id: Int32) -> Int32 {
    return id == Int32.max ? Int32.max : id + 1
}
