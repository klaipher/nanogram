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

// MARK: - Media panel (GIFs, stickers, emoji) height on iPad

/// The share of the container's height the GIF/sticker/emoji panel may take on an iPad.
public let tabletMediaPanelHeightFraction: CGFloat = 0.4

/// The shortest the panel gets on an iPad (the search field, the pack strip and a row or two of the grid still fit),
/// even in a short Split View or Stage Manager window. It never exceeds `standardHeight`.
public let tabletMediaPanelMinimumHeight: CGFloat = 280.0

/// The height of the media panel at rest. Upstream makes it as tall as the system keyboard plus its suggestions bar
/// (`standardHeight`, from the device profile): 491pt of a 13" iPad's 1032pt landscape screen, leaving one message
/// visible, and more than the keyboard the user just had because the profile counts the suggestions bar that the
/// iPad often hides. On an iPad the panel takes at most 40% of `containerHeight` and no more than the system keyboard
/// when its height is known (`keyboardHeight`, nil or zero when unknown), but not less than
/// `tabletMediaPanelMinimumHeight`, and never more than `standardHeight`. A phone keeps `standardHeight`. Dragging the
/// panel up still expands it to the full height (that path does not use this function).
public func tabletMediaPanelHeight(standardHeight: CGFloat, containerHeight: CGFloat, keyboardHeight: CGFloat?, deviceType: DeviceType) -> CGFloat {
    guard deviceType == .tablet, containerHeight > 0.0 else {
        return standardHeight
    }
    var cap = containerHeight * tabletMediaPanelHeightFraction
    if let keyboardHeight = keyboardHeight, keyboardHeight > 0.0 {
        cap = min(cap, keyboardHeight)
    }
    let floorHeight = min(tabletMediaPanelMinimumHeight, standardHeight)
    return min(standardHeight, max(cap, floorHeight))
}

// MARK: - Media panel switcher (GIFs / Stickers / Emoji) on iPad

/// Sizes of the GIFs / Stickers / Emoji switcher at the bottom of the media panel.
public struct MediaPanelSwitcherMetrics: Equatable {
    /// Text size of the three titles.
    public let fontSize: CGFloat
    /// Height of one title's cell (the selection lens is as tall).
    public let itemHeight: CGFloat
    /// Space left and right of a title.
    public let textInset: CGFloat
    /// Height of the lens row, which is also the height the bar reserves above its bottom inset.
    public let rowHeight: CGFloat
    /// Height of the bar above the bottom inset and the 20pt margin.
    public let barIntrinsicHeight: CGFloat
}

/// Upstream's switcher is a 14pt-text pill meant for a phone; at the bottom of an iPad panel it was a small speck.
/// On an iPad it keeps the same floating glass lens (Apple's iPadOS 26 floating tab bar and Telegram's own switcher),
/// with the text at the system body size (17pt) and larger cells. A phone keeps the upstream numbers.
public func mediaPanelSwitcherMetrics(deviceType: DeviceType) -> MediaPanelSwitcherMetrics {
    switch deviceType {
    case .tablet:
        return MediaPanelSwitcherMetrics(fontSize: 17.0, itemHeight: 36.0, textInset: 20.0, rowHeight: 48.0, barIntrinsicHeight: 42.0)
    case .phone:
        return MediaPanelSwitcherMetrics(fontSize: 14.0, itemHeight: 28.0, textInset: 12.0, rowHeight: 40.0, barIntrinsicHeight: 34.0)
    }
}
