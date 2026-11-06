import Foundation
import UIKit
import UIKitRuntimeUtils

/// Nanogram: glass follows the system's own adaptive behaviour on iOS 26 and 27. Telegram instead pins the backdrop
/// luminance native glass sees to a range per theme (the luma clamp, `backdropLayer:didChangeLuma:` in UIKitRuntimeUtils),
/// so its glass does not flip light or dark over the content behind it. That look is kept behind one switch:
/// Debug Settings "Glass: Telegram fixed look", default OFF (native). The clamp is installed once in `+load`, so the
/// switch applies at the next launch; `isActive` is what this launch really did.
public enum GlassFixedLook {
    /// Whether the switch is on in `defaults` (the key UIKitRuntimeUtils reads in `+load`).
    public static func isRequested(in defaults: UserDefaults = .standard) -> Bool {
        return EffectSettingsContainerView.isTelegramFixedLookRequested(in: defaults)
    }

    public static func setRequested(_ requested: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(requested, forKey: EffectSettingsContainerView.telegramFixedLookDefaultsKey)
    }

    /// Whether the clamp is installed in this process. Fixed for the life of the process.
    public static var isActive: Bool {
        return EffectSettingsContainerView.isLumaClampInstalled
    }

    /// The limits for an `EffectSettingsContainerView`: Telegram's ranges when the clamp is installed, otherwise the whole
    /// range (nothing is clamped, and the override that would read the limits is not there anyway).
    static func lumaRange(isDark: Bool, clampInstalled: Bool = GlassFixedLook.isActive) -> (min: Double, max: Double) {
        if clampInstalled {
            return GlassBackgroundView.adaptiveLumaRange(isDark: isDark)
        }
        return (0.0, 1.0)
    }
}
