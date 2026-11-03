import Foundation
import UIKit
import Display

/// The bottom inset a tab's controller gets when it is laid out outside the bar's own layout pass (a tab being
/// selected, `TabBarController.updateControllerLayout`). Upstream estimated it from the old 49pt (34pt in
/// landscape) bar, so the tab laid out once with the wrong inset and its list jumped when the real one arrived;
/// on iPad, with the bar raised for a keyboard, the estimate was far off. When the bar has been laid out for this
/// same layout, its own inset is used (`computedBottomInset`, the space from the bar's top to the bottom edge).
public func tabBarChildBottomInset(layout: ContainerViewLayout, computedLayout: ContainerViewLayout?, computedBottomInset: CGFloat?) -> CGFloat {
    if let computedLayout, let computedBottomInset, computedLayout == layout {
        return computedBottomInset
    }
    var options: ContainerViewLayoutInsetOptions = []
    if layout.metrics.widthClass == .regular {
        options.insert(.input)
    }
    let bottomInset: CGFloat = layout.insets(options: options).bottom
    if !layout.safeInsets.left.isZero {
        return 34.0 + bottomInset
    } else {
        return 49.0 + bottomInset
    }
}
