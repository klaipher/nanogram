import Foundation

/// Holds back the picker's selection relayout while the picker is hidden behind the full-screen gallery or editor.
/// A selection change made there (a caption commit auto-selects the item) relaid out the hidden grid and the
/// attachment panel on the main thread inside the editor's "Done" press (~290 ms). The change is applied once,
/// when the picker is visible again.
public struct MediaPickerSelectionRelayoutGate: Equatable {
    public private(set) var isPending = false

    public init() {
    }

    /// Returns true when the relayout should run now; false when it is held back until `coverEnded()`.
    public mutating func selectionChanged(isCovered: Bool) -> Bool {
        if isCovered {
            self.isPending = true
            return false
        }
        return true
    }

    /// Returns true when a held-back relayout has to run now. Runs it without animation: the picker was not visible.
    public mutating func coverEnded() -> Bool {
        let wasPending = self.isPending
        self.isPending = false
        return wasPending
    }
}
