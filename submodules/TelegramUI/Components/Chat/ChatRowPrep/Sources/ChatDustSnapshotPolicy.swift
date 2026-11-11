import CoreGraphics

/// How the delete "dust" effect snapshots a bubble. `drawHierarchy` at screen scale for a tall bubble can hold the main
/// thread for ~400 ms, so the snapshot is drawn at scale 1.0, and a bubble taller than `maximumHeight` takes the list's
/// normal delete animation instead.
public enum ChatDustSnapshotPolicy {
    public static let maximumHeight: CGFloat = 900.0
    public static let snapshotScale: CGFloat = 1.0

    /// The scale to draw the snapshot at, or nil when the bubble is too tall for the effect.
    public static func snapshotScale(forHeight height: CGFloat) -> CGFloat? {
        return height <= self.maximumHeight ? self.snapshotScale : nil
    }

    /// The effect runs only when every found bubble can be snapshotted.
    public static func isEligible(heights: [CGFloat]) -> Bool {
        return !heights.isEmpty && heights.allSatisfy { self.snapshotScale(forHeight: $0) != nil }
    }
}
