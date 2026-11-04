import Foundation
import UIKit
import SwiftSignalKit
import GameController

// iPad system-API decisions from the iPadOS 27 audit (2026-11-03). Like `TabletLayoutRules.swift`, they are pure
// functions so that the upstream call sites change by a call each and the decisions are unit-tested
// (`//submodules/Display:TabletSystemTests`). Every one is gated on the device being a tablet
// (`DeviceMetrics.type`), never on the width class: iPhone Duo unfolded is a regular-width phone. On a phone each
// reduces to what upstream does.

// MARK: - A-9 Minimum window size

/// The smallest window an iPad user can shrink Nanogram to in Stage Manager or windowed mode: an iPhone-width column
/// that still fits a chat's header, a few messages and the input panel. Nil on phones (they have no resizable
/// windows, and upstream sets nothing).
public func minimumWindowSize(deviceType: DeviceType) -> CGSize? {
    switch deviceType {
    case .tablet:
        return CGSize(width: 375.0, height: 500.0)
    case .phone:
        return nil
    }
}

// MARK: - A-13 Window tint

/// The tint the app's window passes down to system UI it hosts (popovers, pickers, share sheets, menus). Upstream
/// never sets it, so on an iPad those draw in the system blue next to the theme's accent. Nil on phones: leave the
/// window as upstream does.
public func windowSystemTintColor(accentColor: UIColor, deviceType: DeviceType) -> UIColor? {
    switch deviceType {
    case .tablet:
        return accentColor
    case .phone:
        return nil
    }
}

public extension Window1 {
    /// Sets the tint system UI hosted by this window inherits (`windowSystemTintColor`). No change on phones.
    func updateSystemTintColor(accentColor: UIColor) {
        guard let tintColor = windowSystemTintColor(accentColor: accentColor, deviceType: self.deviceType) else {
            return
        }
        let view = self.hostView.eventView
        if view.tintColor != tintColor {
            view.tintColor = tintColor
        }
    }
}

// MARK: - A-13b Which window scene

/// The window scene to act on (orientation requests, the App Store subscription sheet): the scene of the app's own
/// window. `UIApplication.connectedScenes` is an unordered set, and with an external display or another scene
/// connected its `first` can be any of them. Without a window of its own, a foreground-active scene is preferred.
/// With one scene (every iPhone without an external display) the answer is the one upstream gets.
public func preferredWindowScene<Scene>(ownScene: Scene?, connectedScenes: [Scene], isForegroundActive: (Scene) -> Bool) -> Scene? {
    if let ownScene {
        return ownScene
    }
    if let active = connectedScenes.first(where: isForegroundActive) {
        return active
    }
    return connectedScenes.first
}

public extension Window1 {
    /// The scene of this window (`preferredWindowScene`), or the best connected one.
    var preferredWindowScene: UIWindowScene? {
        let connected = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let eventView = self.hostView.eventView
        let ownScene = (eventView as? UIWindow)?.windowScene ?? eventView.window?.windowScene
        return Display.preferredWindowScene(ownScene: ownScene, connectedScenes: connected, isForegroundActive: { $0.activationState == .foregroundActive })
    }
}

// MARK: - B-5 Media prefetch

/// How many media messages the chat prefetches on each side of the visible ones. Upstream stops at 3, about one
/// iPhone screen. One iPad screen shows 4–6 media messages, so on a tablet the count follows the viewport: one per
/// 220pt (a typical photo bubble with its spacing), at least the phone's 3 and at most 8.
public func chatHistoryMediaPrefetchLimit(viewportHeight: CGFloat, deviceType: DeviceType) -> Int {
    let phoneLimit = 3
    switch deviceType {
    case .phone:
        return phoneLimit
    case .tablet:
        guard viewportHeight.isFinite, viewportHeight > 0.0 else {
            return phoneLimit
        }
        let perScreen = Int((viewportHeight / 220.0).rounded(.up))
        return max(phoneLimit, min(8, perScreen))
    }
}

// MARK: - A-12 Text size

/// A signal that fires once at once and, on a tablet, again whenever the system text size changes, so presentation
/// data that follows the system text size ("Use System Text Size") is rebuilt while the app runs. Upstream reads the
/// size once per presentation-data update, so a change made in Control Center or Settings while Nanogram is on screen
/// (common on iPad, beside another app) only applied after a theme change or relaunch. Phones keep that.
public func contentSizeCategoryUpdates(deviceType: DeviceType, notificationCenter: NotificationCenter = .default) -> Signal<Void, NoError> {
    guard case .tablet = deviceType else {
        return .single(Void())
    }
    return Signal { subscriber in
        subscriber.putNext(Void())
        let observer = notificationCenter.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: nil, using: { _ in
            subscriber.putNext(Void())
        })
        return ActionDisposable {
            notificationCenter.removeObserver(observer)
        }
    }
}

/// Whether bar items (the tab bar) show the system Large Content Viewer, the enlarged label shown on a long press at
/// the accessibility text sizes. Tablet only, so the iPhone's long press stays upstream's context menu.
public func showsLargeContentViewer(deviceType: DeviceType) -> Bool {
    return deviceType == .tablet
}

// MARK: - A-7 Popover anchor

/// The rect, in the window's coordinates, that a system share sheet or picker popover points at. On iPad such a
/// controller is a popover, and upstream anchors it to a 1pt rect at the bottom centre of the window, far from the
/// button that opened it. With the button's frame known it points there; without one (or with one off the window)
/// it keeps upstream's anchor. On iPhone these controllers are sheets and ignore the anchor.
public func nativePopoverSourceRect(windowBounds: CGRect, sourceFrame: CGRect?) -> CGRect {
    if let sourceFrame, !sourceFrame.isEmpty, sourceFrame.intersects(windowBounds) {
        return sourceFrame
    }
    return CGRect(origin: CGPoint(x: windowBounds.width / 2.0, y: windowBounds.size.height - 1.0), size: CGSize(width: 1.0, height: 1.0))
}

/// Anchors a system controller's popover (if it has one) at `sourceView` when given and on screen, else at the bottom
/// centre of `window` as upstream did.
public func anchorNativePopover(_ controller: UIViewController, window: UIView, sourceView: UIView?) {
    guard let popover = controller.popoverPresentationController else {
        return
    }
    var sourceFrame: CGRect?
    let hostWindow = (window as? UIWindow) ?? window.window
    if let sourceView, let sourceWindow = sourceView.window, sourceWindow === hostWindow {
        sourceFrame = sourceView.convert(sourceView.bounds, to: window)
    }
    popover.sourceView = window
    popover.sourceRect = nativePopoverSourceRect(windowBounds: window.bounds, sourceFrame: sourceFrame)
}

// MARK: - A-3 Window controls

/// The block iPadOS 26+ reserves in the top-left corner of a window for its window controls (close, minimize,
/// arrange), measured from the corner, or nil when there is none. The system no longer pads custom bars for these
/// in apps linked against the iOS 26+ SDK; the window's safe area adapted to its corners gives the block: the
/// horizontally adapted left inset is how far right content must start beside the controls, the vertically adapted
/// top inset how far down it must start below them. Phones have no window controls.
public func windowControlsCorner(deviceType: DeviceType, safeInsets: UIEdgeInsets, horizontallyAdapted: UIEdgeInsets, verticallyAdapted: UIEdgeInsets) -> CGSize? {
    guard case .tablet = deviceType else {
        return nil
    }
    if horizontallyAdapted.left <= safeInsets.left + 0.5 {
        return nil
    }
    let height = max(verticallyAdapted.top, safeInsets.top)
    if height <= 0.0 {
        return nil
    }
    return CGSize(width: horizontallyAdapted.left, height: height)
}

public extension ContainerViewLayout {
    /// On an iPad window with window controls (`windowControls`, `windowControlsCorner`): how much further than
    /// the left safe inset a navigation bar's leading buttons start, when the bar's button row (which starts at the
    /// status bar's bottom) would sit beside the controls. Zero when the safe area already keeps the row below them,
    /// and on every phone.
    var navigationBarLeadingButtonsInset: CGFloat {
        guard self.deviceMetrics.type == .tablet, let controls = self.windowControls else {
            return 0.0
        }
        let rowMinY = self.statusBarHeight ?? 0.0
        if controls.height <= rowMinY + 0.5 {
            return 0.0
        }
        return max(0.0, controls.width - self.safeInsets.left)
    }
}

// MARK: - Divider: live resize

/// Whether the user is resizing the layout live (dragging the chat-list divider on an iPad). While it is active,
/// views that are expensive to redraw at a new size (the chat wallpaper's pattern) stretch what they have and
/// redraw once when it ends (`didEndNotification`). Only the divider begins it, and the divider exists only on
/// tablets, so phones never see it active.
public final class LiveResizeState {
    public static let didEndNotification = Notification.Name("Display.LiveResizeState.didEnd")
    public static let shared = LiveResizeState(notificationCenter: .default)

    private let notificationCenter: NotificationCenter
    public private(set) var isActive: Bool = false

    public init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    public func begin() {
        self.isActive = true
    }

    /// Ends a live resize and posts `didEndNotification` once; does nothing when none is active.
    public func end() {
        guard self.isActive else {
            return
        }
        self.isActive = false
        self.notificationCenter.post(name: LiveResizeState.didEndNotification, object: self)
    }
}

/// Whether the chat wallpaper keeps its current pattern image, stretched to the new size, instead of drawing it
/// again: only during a live resize, only when it has an image to stretch, and only when nothing but the size
/// changed. Drawing a pattern costs about 9 ms for an iPad chat pane, more than a 120 Hz frame.
public func wallpaperPatternKeepsStretchedImage(isLiveResizing: Bool, hasImage: Bool, onlySizeChanged: Bool) -> Bool {
    return isLiveResizing && hasImage && onlySizeChanged
}

// MARK: - A-16 System Live Text in the media viewer

/// Whether the media viewer adds the system's Live Text (VisionKit: select and copy text, look up, translate, data
/// detectors) to a photo, beside Telegram's own text-recognition button. Tablet only, only where VisionKit's analyzer
/// runs, and never on copy-protected media (no-forwards chats, secret chats), whose text must not be copyable.
public func galleryUsesSystemLiveText(deviceType: DeviceType, isSupported: Bool, isContentProtected: Bool) -> Bool {
    return deviceType == .tablet && isSupported && !isContentProtected
}

// MARK: - iPad keyboard (2026-11-04)

/// Whether a physical keyboard is connected (Smart Keyboard, Magic Keyboard, Bluetooth). With one, the iPad shows
/// no on-screen keyboard, only the shortcuts bar.
public func hardwareKeyboardIsConnected() -> Bool {
    return GCKeyboard.coalesced != nil
}

/// Whether opening a chat from the chat list may put the cursor in the message field. Upstream asks for it on
/// every row tap; on an iPhone that is invisible, but on an iPad the chat is already laid out beside the list,
/// the field takes focus at once and the on-screen keyboard fills the lower half of the screen. On an iPad it is
/// allowed only with a hardware keyboard (typing starts straight away, nothing is covered). Phones are upstream.
public func shouldActivateInputOnChatOpen(requested: Bool, deviceType: DeviceType, hasHardwareKeyboard: Bool) -> Bool {
    guard requested else {
        return false
    }
    switch deviceType {
    case .tablet:
        return hasHardwareKeyboard
    case .phone:
        return true
    }
}

/// Whether the user's finger dragging the message history dismisses the keyboard. The window's interactive
/// keyboard gesture is a phone-only gesture (`Window1`), so on an iPad the drag itself dismisses the on-screen
/// keyboard. Not with a hardware keyboard (the field stays ready for typing) and not when nothing is focused.
public func shouldDismissKeyboardOnHistoryDrag(deviceType: DeviceType, textInputIsFocused: Bool, hasHardwareKeyboard: Bool) -> Bool {
    guard textInputIsFocused else {
        return false
    }
    switch deviceType {
    case .tablet:
        return !hasHardwareKeyboard
    case .phone:
        return false
    }
}
