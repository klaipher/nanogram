public import Foundation
import CoreGraphics

/// Everything a prepared row's layout depends on. A prepared result is used only when the key computed at use time is
/// `==` to the key it was prepared under, so a stale result cannot be used: if one input differs, the row is laid out
/// synchronously as before.
///
/// `Neighbors` is the neighbour descriptor pair (merge flags, date headers) as an `Equatable` value.
public struct ChatRowPrepKey<Neighbors: Equatable>: Equatable {
    /// The row's identity and content version in the list.
    public var stableId: UInt64
    public var stableVersion: Int
    /// The exact item instance: it carries the message, the associated data and the presentation data it was built with.
    public var itemToken: ObjectIdentifier
    /// Layout params.
    public var width: CGFloat
    public var leftInset: CGFloat
    public var rightInset: CGFloat
    public var neighbors: Neighbors
    /// The theme object and the chat font size the item was laid out with.
    public var themeToken: ObjectIdentifier
    public var fontSize: Int32
    /// `ChatControllerInteraction`'s change counter: it moves whenever any state a row's layout reads (selection,
    /// highlight, hidden media, ...) is assigned.
    public var interactionEpoch: UInt64
    public var rotated: Bool
    public var synchronousLoads: Bool

    public init(stableId: UInt64, stableVersion: Int, itemToken: ObjectIdentifier, width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, neighbors: Neighbors, themeToken: ObjectIdentifier, fontSize: Int32, interactionEpoch: UInt64, rotated: Bool, synchronousLoads: Bool) {
        self.stableId = stableId
        self.stableVersion = stableVersion
        self.itemToken = itemToken
        self.width = width
        self.leftInset = leftInset
        self.rightInset = rightInset
        self.neighbors = neighbors
        self.themeToken = themeToken
        self.fontSize = fontSize
        self.interactionEpoch = interactionEpoch
        self.rotated = rotated
        self.synchronousLoads = synchronousLoads
    }
}
