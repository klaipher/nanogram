import UIKit

// Layout decisions for iPad (regular width) that differ from upstream Telegram. They are kept here, as pure
// functions, so that the upstream files they are used from change by a call each (easier merges), and so that
// they can be unit-tested (`//submodules/Display:TabletLayoutTests`). On iPhone each one reduces to the
// upstream expression.

// MARK: - Keyboard notifications

public enum WindowKeyboardNotificationKind {
    case willChangeFrame
    case willHide
}

/// What the window does with a keyboard notification before it measures the end frame.
public enum WindowKeyboardNotificationDecision: Equatable {
    /// Measure the end frame as usual.
    case measure
    /// Nothing occupies the bottom of the screen: the input height becomes zero.
    case hidden
    /// Leave the input height as it is.
    case keep
}

/// On a tablet, a keyboard notification whose end frame is empty means that nothing is docked at the bottom of
/// the screen: the keyboard was undocked or made floating, or the input assistant (shortcuts) bar that the system
/// shows above an empty custom input view (the chat's sticker mode) went away. Upstream ignored such frames, so
/// the last height (about 80pt for that bar) stayed in the layout with nothing drawn in it, and every screen kept
/// an empty band under its input bar until the next keyboard appeared. A hide notification whose end frame is
/// empty or below the screen also means hidden. iPhone keeps the upstream behaviour: there an empty frame is
/// measured (and yields zero) and a hide notification is left to the frame-change one.
public func windowKeyboardNotificationDecision(kind: WindowKeyboardNotificationKind, isTablet: Bool, endFrame: CGRect, screenHeight: CGFloat?) -> WindowKeyboardNotificationDecision {
    switch kind {
    case .willChangeFrame:
        if isTablet && endFrame.isEmpty {
            return .hidden
        }
        return .measure
    case .willHide:
        guard isTablet else {
            return .keep
        }
        if endFrame.isEmpty {
            return .hidden
        }
        if let screenHeight, endFrame.minY >= screenHeight - 1.0 {
            return .hidden
        }
        return .keep
    }
}

// MARK: - Keyboard orientation

/// Whether the on-screen keyboard is in its landscape shape. The keyboard spans the screen, so on a tablet its
/// shape follows the interface (screen) orientation, or the window's shape, not the shape of the pane being laid
/// out: the chat pane of a landscape split view is taller than it is wide. Phones use the pane, as upstream.
public func layoutKeyboardIsLandscape(size: CGSize, deviceType: DeviceType, interfaceOrientation: UIInterfaceOrientation?, windowSize: CGSize?) -> Bool {
    if case .tablet = deviceType {
        if let interfaceOrientation, interfaceOrientation != .unknown {
            return interfaceOrientation.isLandscape
        }
        if let windowSize {
            return windowSize.width > windowSize.height
        }
    }
    return size.width > size.height
}

// MARK: - Floating bottom panels (tab bar, edit toolbars)

/// The smallest reported input height that is a real software keyboard on a tablet. Anything lower is the
/// system's input assistant / shortcuts bar, which never covers a column other than the focused one.
public let tabletRealKeyboardMinimumHeight: CGFloat = 100.0

/// The distance from the bottom edge to a floating bottom panel (the tab bar, a list's edit toolbar). In a
/// regular-width layout the panel rises above the keyboard.
public func floatingBottomPanelsInset(layout: ContainerViewLayout) -> CGFloat {
    var panelsBottomInset: CGFloat = layout.insets(options: []).bottom
    if layout.metrics.widthClass == .regular, let inputHeight = layout.inputHeight, inputHeight > tabletRealKeyboardMinimumHeight {
        panelsBottomInset = inputHeight + 8.0
    }
    if panelsBottomInset == 0.0 {
        panelsBottomInset = 8.0
    } else {
        panelsBottomInset = max(panelsBottomInset, 8.0)
    }
    return panelsBottomInset
}

// MARK: - Sticker panel's bottom bar

/// The frame of the fade behind the sticker/emoji/GIF switch at the bottom of the media panel, in the bar's own
/// coordinates (the switch sits at its top, y = 0). Upstream pins `defaultHeight` to the bar's bottom, which
/// covers the switch only while the bar is short (iPhone). On iPad the bar is lifted above the system's input
/// assistant bar and grows, and the switch ended up over bare grid content.
/// The fade now starts no lower than `mediaPanelBottomBarEdgeEffectOverhang` above the switch, as it does on
/// iPhone (74pt bar: -6), and always reaches the bar's bottom.
public func mediaPanelBottomBarEdgeEffectFrame(barSize: CGSize, defaultHeight: CGFloat) -> CGRect {
    let minY = min(barSize.height - defaultHeight, -mediaPanelBottomBarEdgeEffectOverhang)
    return CGRect(origin: CGPoint(x: 0.0, y: minY), size: CGSize(width: barSize.width, height: barSize.height - minY))
}

/// How far above the switch the fade starts at the least: the iPhone value (74pt bar, 80pt fade).
public let mediaPanelBottomBarEdgeEffectOverhang: CGFloat = 6.0
