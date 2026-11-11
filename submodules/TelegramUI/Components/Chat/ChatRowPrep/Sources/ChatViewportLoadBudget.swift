public import CoreGraphics

/// Which rows of a synchronous-loads pass (the first view of a chat opened without an animation) may decode their
/// photos on the main thread. A row's position is not known while it is built (its height places it), so the rows are
/// counted from the anchor outward: a row starting within the viewport's height of built rows is inside the viewport; one
/// that starts past it is in the preload band (`CoreVirtualListView.preloadMargin`, 160 pt) and loads asynchronously.
public enum ChatViewportLoadBudget {
    /// - Parameters:
    ///   - builtHeight: the height of the rows already built in this pass.
    ///   - viewportHeight: the height of the visible area.
    public static func allowsSynchronousLoad(builtHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        return builtHeight < viewportHeight
    }
}
