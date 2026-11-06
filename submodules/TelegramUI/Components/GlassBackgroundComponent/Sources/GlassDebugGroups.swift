import Foundation
import UIKit

/// Chat glass groups that can be switched off for GPU attribution (Debug Settings, off by default). The raw values are the
/// bits of `ExperimentalUISettings.glassDebugDisabledGroups`.
public enum GlassDebugGroup: Int32, CaseIterable {
    case navigationBar = 1
    case inputPanel = 2
    case floatingButtons = 4
}

/// Which groups are switched off. A glass view finds its group through the nearest `GlassBackgroundContainerView` above it
/// that has a `debugGroup`. With no group off (the default) nothing here costs more than one integer comparison.
public enum GlassDebugGroups {
    /// Bits of `GlassDebugGroup`. Written on the main thread.
    public private(set) static var disabledMask: Int32 = 0

    public static func isDisabled(_ group: GlassDebugGroup) -> Bool {
        return self.disabledMask & group.rawValue != 0
    }

    public static var anyDisabled: Bool {
        return self.disabledMask != 0
    }

    public static func mask(of groups: [GlassDebugGroup]) -> Int32 {
        return groups.reduce(0) { $0 | $1.rawValue }
    }

    public static func groups(in mask: Int32) -> [GlassDebugGroup] {
        return GlassDebugGroup.allCases.filter { mask & $0.rawValue != 0 }
    }

    /// `mask` with `group` turned on or off.
    public static func mask(_ mask: Int32, setting group: GlassDebugGroup, disabled: Bool) -> Int32 {
        return disabled ? (mask | group.rawValue) : (mask & ~group.rawValue)
    }

    public static func setDisabledMask(_ mask: Int32) {
        let known = self.mask(of: GlassDebugGroup.allCases)
        let mask = mask & known
        if self.disabledMask == mask {
            return
        }
        self.disabledMask = mask
        NotificationCenter.default.post(name: GlassEnvironment.didChangeNotification, object: nil)
    }
}
