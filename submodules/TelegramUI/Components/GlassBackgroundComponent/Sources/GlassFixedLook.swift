import Foundation
import UIKit
import UIKitRuntimeUtils

/// Nanogram: glass looks as Telegram 13.2's does, always. Telegram pins the backdrop luminance native glass sees to a
/// range per theme (the luma clamp, `backdropLayer:didChangeLuma:` in UIKitRuntimeUtils, ranges in
/// `GlassBackgroundView.adaptiveLumaRange`), so its glass does not flip light or dark over the content behind it. The
/// clamp is installed once in `+load`; `isActive` is what this launch really did. (Apple's fully native glass had a
/// Debug Settings switch until 2026-11-07; the owner removed it, as it saves no battery.)
public enum GlassFixedLook {
    /// Whether the clamp is installed in this process. Fixed for the life of the process.
    public static var isActive: Bool {
        return EffectSettingsContainerView.isLumaClampInstalled
    }

    /// The limits for an `EffectSettingsContainerView`: Telegram 13.2's ranges when the clamp is installed, otherwise the
    /// whole range (nothing is clamped, and the override that would read the limits is not there anyway).
    static func lumaRange(isDark: Bool, clampInstalled: Bool = GlassFixedLook.isActive) -> (min: Double, max: Double) {
        if clampInstalled {
            return GlassBackgroundView.adaptiveLumaRange(isDark: isDark)
        }
        return (0.0, 1.0)
    }
}
