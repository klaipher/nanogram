import XCTest
import UIKit
import SwiftSignalKit
@testable import Display

/// The iPad system-API decisions in `TabletSystemRules.swift` (audit 2026-11-03: A-3, A-7, A-9, A-12, A-13,
/// A-13b, A-16, B-5 and the divider's background stretch). Every case pairs the iPad behaviour with the phone one,
/// which must stay what upstream does.
final class TabletSystemRulesTests: XCTestCase {
    // MARK: A-9 Minimum window size

    func test_tablet_hasMinimumWindowSize() {
        XCTAssertEqual(minimumWindowSize(deviceType: .tablet), CGSize(width: 375.0, height: 500.0))
    }

    func test_phone_hasNoMinimumWindowSize() {
        XCTAssertNil(minimumWindowSize(deviceType: .phone))
    }

    // MARK: A-13 Window tint

    func test_tablet_windowTintIsTheAccent() {
        let accent = UIColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0)
        XCTAssertEqual(windowSystemTintColor(accentColor: accent, deviceType: .tablet), accent)
    }

    func test_phone_windowTintIsUntouched() {
        XCTAssertNil(windowSystemTintColor(accentColor: .red, deviceType: .phone))
    }

    // MARK: A-13b Which window scene

    func test_ownSceneWins() {
        XCTAssertEqual(preferredWindowScene(ownScene: "app", connectedScenes: ["external", "app"], isForegroundActive: { _ in true }), "app")
    }

    /// Without a window of its own, a foreground-active scene is preferred over whichever the unordered set lists first.
    func test_withoutOwnScene_foregroundActiveIsPreferred() {
        XCTAssertEqual(preferredWindowScene(ownScene: nil, connectedScenes: ["background", "active"], isForegroundActive: { $0 == "active" }), "active")
    }

    func test_withoutOwnScene_noActive_fallsBackToFirst() {
        XCTAssertEqual(preferredWindowScene(ownScene: nil, connectedScenes: ["one", "two"], isForegroundActive: { _ in false }), "one")
        XCTAssertNil(preferredWindowScene(ownScene: nil as String?, connectedScenes: [], isForegroundActive: { _ in true }))
    }

    // MARK: B-5 Media prefetch

    func test_phone_prefetchesThreeEachWay() {
        XCTAssertEqual(chatHistoryMediaPrefetchLimit(viewportHeight: 874.0, deviceType: .phone), 3)
        XCTAssertEqual(chatHistoryMediaPrefetchLimit(viewportHeight: 951.0, deviceType: .phone), 3)
    }

    /// One iPad screen shows 4–6 media messages; the prefetch reaches about one more screen each way.
    func test_tablet_prefetchScalesWithViewport() {
        XCTAssertEqual(chatHistoryMediaPrefetchLimit(viewportHeight: 1032.0, deviceType: .tablet), 5)
        XCTAssertEqual(chatHistoryMediaPrefetchLimit(viewportHeight: 1376.0, deviceType: .tablet), 7)
        // Never below the phone's value, never unbounded.
        XCTAssertEqual(chatHistoryMediaPrefetchLimit(viewportHeight: 400.0, deviceType: .tablet), 3)
        XCTAssertEqual(chatHistoryMediaPrefetchLimit(viewportHeight: 4000.0, deviceType: .tablet), 8)
    }

    // MARK: A-12 Text size changes

    func test_tablet_textSizeChangeEmits() {
        let center = NotificationCenter()
        var count = 0
        let disposable = contentSizeCategoryUpdates(deviceType: .tablet, notificationCenter: center).start(next: { _ in
            count += 1
        })
        XCTAssertEqual(count, 1, "the current value at once")
        center.post(name: UIContentSizeCategory.didChangeNotification, object: nil)
        XCTAssertEqual(count, 2)
        disposable.dispose()
        center.post(name: UIContentSizeCategory.didChangeNotification, object: nil)
        XCTAssertEqual(count, 2, "no updates after dispose")
    }

    func test_phone_textSizeChangeIsIgnored() {
        let center = NotificationCenter()
        var count = 0
        let disposable = contentSizeCategoryUpdates(deviceType: .phone, notificationCenter: center).start(next: { _ in
            count += 1
        })
        center.post(name: UIContentSizeCategory.didChangeNotification, object: nil)
        XCTAssertEqual(count, 1, "upstream reads the size once")
        disposable.dispose()
    }

    func test_largeContentViewer_tabletOnly() {
        XCTAssertTrue(showsLargeContentViewer(deviceType: .tablet))
        XCTAssertFalse(showsLargeContentViewer(deviceType: .phone))
    }

    // MARK: A-7 Popover anchor

    func test_popoverAnchorsToTheSource() {
        let window = CGRect(x: 0.0, y: 0.0, width: 1376.0, height: 1032.0)
        let button = CGRect(x: 1300.0, y: 30.0, width: 44.0, height: 44.0)
        XCTAssertEqual(nativePopoverSourceRect(windowBounds: window, sourceFrame: button), button)
    }

    /// Without a source (or one off screen, or empty) the anchor stays where upstream puts it: the bottom centre.
    func test_popoverWithoutSource_isUpstream() {
        let window = CGRect(x: 0.0, y: 0.0, width: 1376.0, height: 1032.0)
        let upstream = CGRect(x: 688.0, y: 1031.0, width: 1.0, height: 1.0)
        XCTAssertEqual(nativePopoverSourceRect(windowBounds: window, sourceFrame: nil), upstream)
        XCTAssertEqual(nativePopoverSourceRect(windowBounds: window, sourceFrame: CGRect(x: 2000.0, y: 30.0, width: 44.0, height: 44.0)), upstream)
        XCTAssertEqual(nativePopoverSourceRect(windowBounds: window, sourceFrame: CGRect(x: 10.0, y: 10.0, width: 0.0, height: 0.0)), upstream)
    }

    // MARK: A-3 Window controls

    /// iPadOS 26 windowed: the controls sit in the top-left corner; the horizontally adapted safe area reaches past
    /// them, the vertically adapted one below them.
    func test_tablet_windowControlsCorner() {
        let corner = windowControlsCorner(deviceType: .tablet, safeInsets: UIEdgeInsets(top: 24.0, left: 0.0, bottom: 20.0, right: 0.0), horizontallyAdapted: UIEdgeInsets(top: 24.0, left: 86.0, bottom: 20.0, right: 0.0), verticallyAdapted: UIEdgeInsets(top: 52.0, left: 0.0, bottom: 20.0, right: 0.0))
        XCTAssertEqual(corner, CGSize(width: 86.0, height: 52.0))
    }

    func test_tablet_noControls_noCorner() {
        let insets = UIEdgeInsets(top: 24.0, left: 0.0, bottom: 20.0, right: 0.0)
        XCTAssertNil(windowControlsCorner(deviceType: .tablet, safeInsets: insets, horizontallyAdapted: insets, verticallyAdapted: insets))
    }

    func test_phone_noControlsCorner() {
        XCTAssertNil(windowControlsCorner(deviceType: .phone, safeInsets: UIEdgeInsets(), horizontallyAdapted: UIEdgeInsets(top: 0.0, left: 86.0, bottom: 0.0, right: 0.0), verticallyAdapted: UIEdgeInsets(top: 52.0, left: 0.0, bottom: 0.0, right: 0.0)))
    }

    private func layout(deviceMetrics: DeviceMetrics, windowControls: CGSize?, statusBarHeight: CGFloat?, safeLeft: CGFloat = 0.0) -> ContainerViewLayout {
        var layout = ContainerViewLayout(size: CGSize(width: 900.0, height: 700.0), metrics: LayoutMetrics(widthClass: .regular, heightClass: .regular, orientation: nil), deviceMetrics: deviceMetrics, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(top: 0.0, left: safeLeft, bottom: 0.0, right: 0.0), reservedCorners: .none, division: nil, additionalInsets: UIEdgeInsets(), statusBarHeight: statusBarHeight, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
        layout.windowControls = windowControls
        return layout
    }

    /// A bar whose button row starts above the controls' bottom edge moves its leading buttons past them.
    func test_tablet_leadingButtonsClearTheControls() {
        let controls = CGSize(width: 86.0, height: 52.0)
        XCTAssertEqual(self.layout(deviceMetrics: .iPadPro13InchM4, windowControls: controls, statusBarHeight: 24.0).navigationBarLeadingButtonsInset, 86.0)
        // Only beyond the safe inset already applied.
        XCTAssertEqual(self.layout(deviceMetrics: .iPadPro13InchM4, windowControls: controls, statusBarHeight: 24.0, safeLeft: 20.0).navigationBarLeadingButtonsInset, 66.0)
    }

    /// The safe area already keeps the row below the controls: nothing moves.
    func test_tablet_rowBelowTheControls_noInset() {
        XCTAssertEqual(self.layout(deviceMetrics: .iPadPro13InchM4, windowControls: CGSize(width: 86.0, height: 24.0), statusBarHeight: 24.0).navigationBarLeadingButtonsInset, 0.0)
        XCTAssertEqual(self.layout(deviceMetrics: .iPadPro13InchM4, windowControls: nil, statusBarHeight: 24.0).navigationBarLeadingButtonsInset, 0.0)
    }

    func test_phone_noLeadingInset() {
        XCTAssertEqual(self.layout(deviceMetrics: .iPhoneDuo, windowControls: CGSize(width: 86.0, height: 52.0), statusBarHeight: 0.0).navigationBarLeadingButtonsInset, 0.0)
    }

    /// The `with…` copies keep the controls (the window sets them; navigation containers derive layouts from it).
    func test_layoutCopies_keepWindowControls() {
        let layout = self.layout(deviceMetrics: .iPadPro13InchM4, windowControls: CGSize(width: 86.0, height: 52.0), statusBarHeight: 24.0)
        XCTAssertEqual(layout.withUpdatedSize(CGSize(width: 500.0, height: 700.0)).windowControls, CGSize(width: 86.0, height: 52.0))
        XCTAssertEqual(layout.withUpdatedInputHeight(300.0).windowControls, CGSize(width: 86.0, height: 52.0))
        XCTAssertEqual(layout.addedInsets(insets: UIEdgeInsets(top: 1.0, left: 0.0, bottom: 0.0, right: 0.0)).windowControls, CGSize(width: 86.0, height: 52.0))
        XCTAssertEqual(layout.withUpdatedMetrics(LayoutMetrics()).windowControls, CGSize(width: 86.0, height: 52.0))
    }

    // MARK: Divider: the chat background stretches while dragging

    func test_liveResize_beginEnd_postsOnce() {
        let center = NotificationCenter()
        let state = LiveResizeState(notificationCenter: center)
        var ends = 0
        let observer = center.addObserver(forName: LiveResizeState.didEndNotification, object: nil, queue: nil, using: { _ in
            ends += 1
        })
        XCTAssertFalse(state.isActive)
        state.begin()
        XCTAssertTrue(state.isActive)
        state.end()
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(ends, 1)
        state.end()
        XCTAssertEqual(ends, 1, "ending twice posts once")
        center.removeObserver(observer)
    }

    func test_patternKeepsStretchedImage_onlyWhileResizing() {
        XCTAssertTrue(wallpaperPatternKeepsStretchedImage(isLiveResizing: true, hasImage: true, onlySizeChanged: true))
        // Not resizing: regenerate at the new size, as upstream.
        XCTAssertFalse(wallpaperPatternKeepsStretchedImage(isLiveResizing: false, hasImage: true, onlySizeChanged: true))
        // Nothing to stretch yet, or the pattern itself changed: draw it.
        XCTAssertFalse(wallpaperPatternKeepsStretchedImage(isLiveResizing: true, hasImage: false, onlySizeChanged: true))
        XCTAssertFalse(wallpaperPatternKeepsStretchedImage(isLiveResizing: true, hasImage: true, onlySizeChanged: false))
    }

    // MARK: A-16 System Live Text in the media viewer

    func test_systemLiveText_tabletOnly_unprotected() {
        XCTAssertTrue(galleryUsesSystemLiveText(deviceType: .tablet, isSupported: true, isContentProtected: false))
        XCTAssertFalse(galleryUsesSystemLiveText(deviceType: .phone, isSupported: true, isContentProtected: false))
        XCTAssertFalse(galleryUsesSystemLiveText(deviceType: .tablet, isSupported: false, isContentProtected: false))
        // Copy-protected media (no forwards, secret chats) must not offer copying its text.
        XCTAssertFalse(galleryUsesSystemLiveText(deviceType: .tablet, isSupported: true, isContentProtected: true))
    }

    // MARK: iPad keyboard

    func test_openChat_tablet_noHardwareKeyboard_doesNotFocus() {
        XCTAssertFalse(shouldActivateInputOnChatOpen(requested: true, deviceType: .tablet, hasHardwareKeyboard: false))
    }

    func test_openChat_tablet_hardwareKeyboard_focuses() {
        XCTAssertTrue(shouldActivateInputOnChatOpen(requested: true, deviceType: .tablet, hasHardwareKeyboard: true))
    }

    func test_openChat_notRequested_neverFocuses() {
        XCTAssertFalse(shouldActivateInputOnChatOpen(requested: false, deviceType: .tablet, hasHardwareKeyboard: true))
        XCTAssertFalse(shouldActivateInputOnChatOpen(requested: false, deviceType: .phone, hasHardwareKeyboard: false))
    }

    func test_openChat_phone_isUpstream() {
        XCTAssertTrue(shouldActivateInputOnChatOpen(requested: true, deviceType: .phone, hasHardwareKeyboard: false))
        XCTAssertTrue(shouldActivateInputOnChatOpen(requested: true, deviceType: .phone, hasHardwareKeyboard: true))
    }

    func test_historyDrag_tablet_softwareKeyboard_dismisses() {
        XCTAssertTrue(shouldDismissKeyboardOnHistoryDrag(deviceType: .tablet, textInputIsFocused: true, hasHardwareKeyboard: false))
    }

    func test_historyDrag_tablet_hardwareKeyboard_keepsFocus() {
        XCTAssertFalse(shouldDismissKeyboardOnHistoryDrag(deviceType: .tablet, textInputIsFocused: true, hasHardwareKeyboard: true))
    }

    func test_historyDrag_nothingFocused_doesNothing() {
        XCTAssertFalse(shouldDismissKeyboardOnHistoryDrag(deviceType: .tablet, textInputIsFocused: false, hasHardwareKeyboard: false))
    }

    func test_historyDrag_phone_leavesItToTheWindowGesture() {
        XCTAssertFalse(shouldDismissKeyboardOnHistoryDrag(deviceType: .phone, textInputIsFocused: true, hasHardwareKeyboard: false))
    }
}
