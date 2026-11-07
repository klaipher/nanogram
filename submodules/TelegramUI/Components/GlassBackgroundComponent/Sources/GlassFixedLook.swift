import Foundation
import UIKit
import UIKitRuntimeUtils

/// Nanogram: glass looks as Telegram 13.2's does by default. Telegram pins the backdrop luminance native glass sees to a
/// range per theme (the luma clamp, `backdropLayer:didChangeLuma:` in UIKitRuntimeUtils, ranges in
/// `GlassBackgroundView.adaptiveLumaRange`), so its glass does not flip light or dark over the content behind it.
/// Apple's fully native glass, without the clamp, is behind one switch: Debug Settings "Glass: native (no Telegram
/// clamp)", default OFF. The clamp is installed once in `+load`, so the switch applies at the next launch; `isActive` is
/// what this launch really did.
public enum GlassFixedLook {
    /// Whether the native switch is on in `defaults` (the key UIKitRuntimeUtils reads in `+load`).
    public static func isNativeRequested(in defaults: UserDefaults = .standard) -> Bool {
        return EffectSettingsContainerView.isNativeNoClampRequested(in: defaults)
    }

    public static func setNativeRequested(_ requested: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(requested, forKey: EffectSettingsContainerView.nativeNoClampDefaultsKey)
    }

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
