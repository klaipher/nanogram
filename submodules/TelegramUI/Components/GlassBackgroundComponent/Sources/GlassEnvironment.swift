import Foundation
import UIKit

/// The system settings that change how glass must look, as plain values so the decisions below can be tested.
public struct GlassAccessibilityState: Equatable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool

    public init(reduceTransparency: Bool, increaseContrast: Bool) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }

    public static let standard = GlassAccessibilityState(reduceTransparency: false, increaseContrast: false)

    public static var current: GlassAccessibilityState {
        return GlassAccessibilityState(reduceTransparency: UIAccessibility.isReduceTransparencyEnabled, increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled)
    }
}

/// Decisions for the parts of glass that Telegram draws itself. System glass (UIGlassEffect) follows Reduce Transparency
/// and Increase Contrast on its own (frostier, black or white with a border); these functions give the custom parts the
/// same behaviour: the legacy fill of the glass before iOS 26, and the blur radius override of the context menu.
public enum GlassAccessibility {
    /// The base the glass of a light or dark appearance sits on when it is made opaque.
    static func solidBase(isDark: Bool) -> UIColor {
        // The legacy panel's dark fill is white mixed to 11% over black.
        return isDark ? UIColor(white: 0.11, alpha: 1.0) : UIColor(white: 1.0, alpha: 1.0)
    }

    /// `color` laid over `base`, as one opaque colour.
    static func composite(_ color: UIColor, over base: UIColor) -> UIColor {
        var r0: CGFloat = 0.0, g0: CGFloat = 0.0, b0: CGFloat = 0.0, a0: CGFloat = 0.0
        var r1: CGFloat = 0.0, g1: CGFloat = 0.0, b1: CGFloat = 0.0, a1: CGFloat = 0.0
        guard color.getRed(&r0, green: &g0, blue: &b0, alpha: &a0), base.getRed(&r1, green: &g1, blue: &b1, alpha: &a1) else {
            return base
        }
        return UIColor(red: r1 + (r0 - r1) * a0, green: g1 + (g0 - g1) * a0, blue: b1 + (b0 - b1) * a0, alpha: 1.0)
    }

    /// The fill and the edge width factor of the legacy (non-native) glass for a fill colour that is wanted as `fillColor`.
    /// With Reduce Transparency the fill is opaque (the colour over the appearance's base, so a translucent accent keeps its
    /// look instead of turning saturated); with Increase Contrast the edge is twice as wide. Without either the inputs come
    /// back unchanged.
    public static func legacyFill(fillColor: UIColor, borderWidthFactor: CGFloat, isDark: Bool, state: GlassAccessibilityState) -> (fillColor: UIColor, borderWidthFactor: CGFloat) {
        var fill = fillColor
        var border = borderWidthFactor
        if state.reduceTransparency {
            fill = composite(fillColor, over: solidBase(isDark: isDark))
        }
        if state.increaseContrast {
            border *= 2.0
        }
        return (fill, border)
    }

    /// The blur radius override to apply: none (the system's own) while Reduce Transparency is on, since the system makes
    /// its glass frosty then and a custom radius would put the see-through back.
    public static func effectiveBlurRadius(requested: CGFloat?, state: GlassAccessibilityState) -> CGFloat? {
        if state.reduceTransparency {
            return nil
        }
        return requested
    }
}

/// Posts `didChangeNotification` when something that glass views read changes: Reduce Transparency, Increase Contrast, or
/// the debug groups. Views reapply their state when it arrives.
public final class GlassEnvironment {
    public static let didChangeNotification = Notification.Name("GlassEnvironmentDidChange")

    public static let shared = GlassEnvironment()

    private var tokens: [NSObjectProtocol] = []

    private init() {
    }

    /// Starts listening to the accessibility settings. Idempotent.
    public func start() {
        if !self.tokens.isEmpty {
            return
        }
        for name in [UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIAccessibility.darkerSystemColorsStatusDidChangeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: { _ in
                NotificationCenter.default.post(name: GlassEnvironment.didChangeNotification, object: nil)
            })
            self.tokens.append(token)
        }
    }
}
