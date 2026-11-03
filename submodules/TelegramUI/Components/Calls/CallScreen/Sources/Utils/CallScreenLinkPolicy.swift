import Foundation
import CoreGraphics

/// When the call screen's display links need to run. Each of them used to run for as long as its view was in a
/// window; now they run only while something on screen is changing.
public enum CallScreenLinkPolicy {
    /// The audio-level smoothing moves the avatar and blob scale. At rest (no level, no target, no bump) it does
    /// nothing, so the link is dropped until a new level arrives.
    public static func audioLevelNeedsLink(audioLevel: Float, target: Float, bump: Float) -> Bool {
        return audioLevel > 0.0 || target > 0.0 || bump > 0.0
    }

    /// The smoothing step was written for 60 Hz frames (keep 80 percent of the old level per frame). Expressing it
    /// per second keeps the same feel at 30 Hz, 120 Hz or after a stalled frame.
    public static func attenuationKeep(deltaTime: Double) -> Float {
        let frames = max(0.0, deltaTime) * 60.0
        return Float(pow(0.8, frames))
    }

    /// A layer transform is rewritten only when the scale visibly changed.
    public static func shouldWriteScale(previous: CGFloat, new: CGFloat) -> Bool {
        return abs(previous - new) > 0.001
    }

    /// The animated background drifts continuously unless energy saving freezes it; frozen, it still needs
    /// frames while a colour or acceleration animation runs.
    public static func backgroundNeedsLink(isInHierarchy: Bool, isEnergySaving: Bool, hasRunningAnimation: Bool) -> Bool {
        return isInHierarchy && (!isEnergySaving || hasRunningAnimation)
    }

    /// The audio-level blob is drawn only while it is shown (not muted, not terminated, not energy saving).
    public static func blobsNeedLink(isInHierarchy: Bool, isShown: Bool) -> Bool {
        return isInHierarchy && isShown
    }

    /// The call screen's energy-saving flag is the inverse of the live "full translucency" setting.
    public static func isEnergySaving(fullTranslucency: Bool) -> Bool {
        return !fullTranslucency
    }
}
