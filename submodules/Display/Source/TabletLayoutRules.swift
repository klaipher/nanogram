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

/// On an iPad in a regular-width window, a keyboard notification whose end frame is empty means that nothing is
/// docked at the bottom of the screen: the keyboard was undocked or made floating, or the input assistant
/// (shortcuts) bar went away. Upstream ignored such frames, so the last height (about 80pt for that bar) stayed in
/// the layout with nothing drawn in it, and every screen kept an empty band under its input bar until the next
/// keyboard appeared. A hide notification whose end frame is empty or below the screen also means hidden.
/// Everything else keeps the upstream behaviour: a regular-width phone (iPhone Duo unfolded) ignores an empty
/// frame, a compact window measures it (and gets zero), and a hide is left to the frame-change notification.
public func windowKeyboardNotificationDecision(kind: WindowKeyboardNotificationKind, isRegularWidth: Bool, deviceType: DeviceType, endFrame: CGRect, screenHeight: CGFloat?) -> WindowKeyboardNotificationDecision {
    let isTabletRegular = isRegularWidth && deviceType == .tablet
    switch kind {
    case .willChangeFrame:
        if isRegularWidth && endFrame.isEmpty {
            return isTabletRegular ? .hidden : .keep
        }
        return .measure
    case .willHide:
        guard isTabletRegular else {
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

/// The distance from the bottom edge to a floating bottom panel (the tab bar, a list's edit toolbar). In a
/// regular-width layout the panel rises above whatever the system reports at the bottom: a keyboard, a hardware
/// keyboard's shortcuts bar, or the part of a keyboard that overlaps a Stage Manager window. This is the upstream
/// rule, shared by both call sites. (It once ignored heights up to 100pt, for the ~80pt assistant bar of the
/// chat's sticker mode; that bar is no longer shown at all, `ChatInputAssistantSuppressor`, and the cutoff left
/// the tab bar under a real shortcuts bar.)
public func floatingBottomPanelsInset(layout: ContainerViewLayout) -> CGFloat {
    var panelsBottomInset: CGFloat = layout.insets(options: []).bottom
    if layout.metrics.widthClass == .regular, let inputHeight = layout.inputHeight, inputHeight != 0.0 {
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
    if barSize.height <= mediaPanelBottomBarMaximumUnliftedHeight {
        // Not lifted (every iPhone, an iPad without the assistant bar): the upstream frame.
        return CGRect(origin: CGPoint(x: 0.0, y: barSize.height - defaultHeight), size: CGSize(width: barSize.width, height: defaultHeight))
    }
    let minY = min(barSize.height - defaultHeight, -mediaPanelBottomBarEdgeEffectOverhang)
    return CGRect(origin: CGPoint(x: 0.0, y: minY), size: CGSize(width: barSize.width, height: barSize.height - minY))
}

/// How far above the switch the fade starts at the least: the iPhone value (74pt bar, 80pt fade).
public let mediaPanelBottomBarEdgeEffectOverhang: CGFloat = 6.0

/// The tallest bar that is not lifted: 34pt switch row, the largest home-indicator inset (34pt, iPhone before
/// iOS 26) and 20pt below. Bars up to this height keep the upstream fade.
public let mediaPanelBottomBarMaximumUnliftedHeight: CGFloat = 88.0
