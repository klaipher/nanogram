/// The change counter behind `ChatControllerInteraction.rowPrepEpoch`. It moves when state a row's layout reads actually
/// changes. A property that is assigned every frame with the same value (`recommendedChannelsOpenUp` on each scroll
/// frame, `canReadHistory` and `focusedTextInputIsMedia` on each interface-state update) must not move it, or a prepared
/// row would be evicted one frame after it was prepared.
///
/// Main thread only.
public struct ChatRowPrepEpoch {
    public private(set) var value: UInt64 = 0

    public init() {
    }

    /// The value was assigned; it counts only if it differs from what it replaced.
    public mutating func noteAssignment<Value: Equatable>(from oldValue: Value, to newValue: Value) {
        if oldValue != newValue {
            self.value &+= 1
        }
    }

    /// For state that cannot be compared cheaply (collections of media, settings structs): every assignment counts. Use
    /// only for properties that are written rarely.
    public mutating func noteChange() {
        self.value &+= 1
    }
}
