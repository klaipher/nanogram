import Foundation
import CoreGraphics

/// Which parts of a glass container's state `GlassBackgroundContainerView.update` has to apply: only those that differ from
/// what it applied last. Kept apart from the view so the decision can be tested without UIKit.
public enum GlassContainerUpdateGate {
    public struct Changes: Equatable {
        public let size: Bool
        public let isDark: Bool

        public var any: Bool {
            return self.size || self.isDark
        }
    }

    public static func changes(applied: (size: CGSize, isDark: Bool)?, size: CGSize, isDark: Bool) -> Changes {
        guard let applied else {
            return Changes(size: true, isDark: true)
        }
        return Changes(size: applied.size != size, isDark: applied.isDark != isDark)
    }
}
