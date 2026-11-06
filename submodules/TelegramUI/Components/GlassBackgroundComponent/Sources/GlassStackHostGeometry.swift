import Foundation
import CoreGraphics

/// Where a `GlassBackgroundContainerView` and the plain view inside it go so that glass views which already have
/// positions in some owner's coordinate space (here: the floating chat buttons, stacked up to 208 pt beyond the owner's
/// bounds) can move into a container without changing a single one of those positions.
///
/// The container is sized to the extent of the content plus a margin for scale-up animations and badges; the stack view is
/// put at `stackOrigin` inside the container's content view, and the glass views go into the stack view at their old
/// positions. The container's frame (in the owner's coordinates) is `hostFrame`.
public struct GlassStackHostGeometry: Equatable {
    public let hostFrame: CGRect
    public let stackOrigin: CGPoint

    /// - Parameters:
    ///   - contentFrame: the union of every frame the content can take, in the owner's coordinates.
    ///   - margin: extra room on every side.
    public init(contentFrame: CGRect, margin: CGFloat) {
        let margin = max(0.0, margin)
        self.hostFrame = contentFrame.insetBy(dx: -margin, dy: -margin)
        self.stackOrigin = CGPoint(x: -self.hostFrame.minX, y: -self.hostFrame.minY)
    }

    /// Where a point of the owner's coordinate space is in the host.
    public func hostPoint(forOwnerPoint point: CGPoint) -> CGPoint {
        return CGPoint(x: point.x + self.stackOrigin.x, y: point.y + self.stackOrigin.y)
    }
}
