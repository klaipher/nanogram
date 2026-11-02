import Foundation
import UIKit

/// The system switch an `ItemListSwitchItem` row shows. Its width depends on the OS the app runs on,
/// not on the list's `ItemListSystemStyle`: a `.glass` list on iOS 18 still gets the old switch.
public enum ItemListSwitchControlStyle: Equatable {
    /// `UISwitch` before iOS 26: 51 x 31 pt.
    case legacy
    /// The iOS 26+ ("Liquid Glass") `UISwitch`: 63 x 28 pt.
    case glass

    public static var current: ItemListSwitchControlStyle {
        if #available(iOS 26.0, *) {
            return .glass
        } else {
            return .legacy
        }
    }

    /// Width of the switch as UIKit sizes it (`sizeToFit`), the size the row lays it out at.
    /// Matches `SwitchNode.calculateSizeThatFits`; `ItemListUITests` measures a real `UISwitch`.
    public var switchWidth: CGFloat {
        switch self {
        case .legacy:
            return 51.0
        case .glass:
            return 63.0
        }
    }
}

/// Horizontal layout of an `ItemListSwitchItem` row: the switch sits `switchTrailingInset` from the
/// row's right inset, and the title stops `titleToSwitchSpacing` before the switch.
public enum ItemListSwitchItemMetrics {
    /// Gap between the switch's right edge and the row's right inset.
    public static let switchTrailingInset: CGFloat = 15.0
    /// Minimum gap between the end of the title and the switch's left edge.
    public static let titleToSwitchSpacing: CGFloat = 10.0

    /// The widest the title may be laid out, given the row width, the title's leading x
    /// (`leftInset`, already including the row's own left inset and any icon) and the row's right inset.
    public static func titleMaxWidth(rowWidth: CGFloat, leftInset: CGFloat, rightInset: CGFloat, switchStyle: ItemListSwitchControlStyle) -> CGFloat {
        let switchFootprint = self.switchTrailingInset + switchStyle.switchWidth + self.titleToSwitchSpacing
        return max(0.0, rowWidth - leftInset - rightInset - switchFootprint)
    }

    /// The x of the switch's left edge for a switch of `switchWidth`.
    public static func switchMinX(rowWidth: CGFloat, rightInset: CGFloat, switchWidth: CGFloat) -> CGFloat {
        return rowWidth - rightInset - switchWidth - switchTrailingInset
    }
}
