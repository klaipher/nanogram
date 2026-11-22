import Foundation
import CoreGraphics

/// Whether one glass view that sits in a shared `GlassBackgroundContainerView` is meant to be seen.
///
/// The native container (`UIGlassContainerEffect`) builds its shapes from its members' geometry (frame and transform), and
/// measurably keeps drawing a member whose own alpha is 0 or whose owner is `isHidden`: a floating chat button hidden by
/// alpha 0 and scale 0.2 stayed as an 8 pt dot in the container and merged with the visible button into a droplet. A member
/// that must not show therefore has to stop being glass (`isVisible: false` on its `GlassBackgroundView`, which drops the
/// effect), not just fade. This type holds that decision so the owner cannot forget one of the paths:
///
/// - a member starts hidden, so one that was never shown is never glass;
/// - hiding and showing return whether the glass has to be updated, so an unchanged state costs nothing;
/// - a hide animation's completion only commits `isHidden` while the member is still meant to be hidden (a show that
///   replaced the animation delivers `completed == false` for the old one, and a late `true` must not hide a shown button).
public struct GlassMemberVisibility: Equatable {
    /// Whether the member is meant to be visible. False until `show()`.
    public private(set) var isShown: Bool = false

    public init() {
    }

    /// Returns true when the member went from hidden to shown (the owner then passes `isVisible: true` BEFORE it starts the
    /// show animation).
    public mutating func show() -> Bool {
        if isShown { return false }
        isShown = true
        return true
    }

    /// Returns true when the member went from shown to hidden (the owner then passes `isVisible: false` as the hide starts).
    public mutating func hide() -> Bool {
        if !isShown { return false }
        isShown = false
        return true
    }

    /// Whether a hide animation's completion may set the node `isHidden`.
    public func mayCommitHidden(animationCompleted: Bool) -> Bool {
        return animationCompleted && !isShown
    }

    /// The shared container is hidden exactly when no member is visible (`memberIsHidden` per member).
    public static func containerIsVisible(memberIsHidden: [Bool]) -> Bool {
        return memberIsHidden.contains(false)
    }

    /// A member that is invisible by alpha but not hidden and not animating: it will never be hidden by a completion that
    /// is not coming. Diagnostics only.
    public static func isStuckMember(layerOpacity: Float, isHidden: Bool, hasRunningOpacityAnimation: Bool, isShown: Bool) -> Bool {
        return !isShown && !isHidden && layerOpacity == 0.0 && !hasRunningOpacityAnimation
    }
}
