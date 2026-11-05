import XCTest
import UIKit
@testable import Display

/// The iPad layout decisions in `TabletLayoutRules.swift` and the iPad rows of `DeviceMetrics`. Every case pairs
/// the iPad behaviour with the phone (compact) one, which must stay what upstream does.
final class TabletLayoutRulesTests: XCTestCase {
    private func layout(size: CGSize, widthClass: ContainerViewLayoutSizeClass, deviceMetrics: DeviceMetrics = .iPadPro11Inch, bottomInset: CGFloat = 20.0, inputHeight: CGFloat?, orientation: UIInterfaceOrientation? = nil, windowSize: CGSize? = nil) -> ContainerViewLayout {
        return ContainerViewLayout(size: size, metrics: LayoutMetrics(widthClass: widthClass, heightClass: widthClass, orientation: orientation, windowSize: windowSize), deviceMetrics: deviceMetrics, intrinsicInsets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: bottomInset, right: 0.0), safeInsets: UIEdgeInsets(), reservedCorners: .none, division: nil, additionalInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: inputHeight, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
    }

    // MARK: Keyboard notifications

    /// The owner's iPad: the input assistant bar of sticker mode (about 80pt) went away with an empty end frame,
    /// and the height stayed. An empty frame on a tablet now means nothing is docked.
    func test_tablet_emptyFrameChange_isHidden() {
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: true, deviceType: .tablet, endFrame: .zero, screenHeight: 1032.0), .hidden)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: true, deviceType: .tablet, endFrame: CGRect(x: 0.0, y: 952.0, width: 1376.0, height: 0.0), screenHeight: 1032.0), .hidden)
    }

    func test_tablet_hideWithEmptyOrOffscreenFrame_isHidden() {
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willHide, isRegularWidth: true, deviceType: .tablet, endFrame: .zero, screenHeight: 1032.0), .hidden)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willHide, isRegularWidth: true, deviceType: .tablet, endFrame: CGRect(x: 0.0, y: 1032.0, width: 1376.0, height: 80.0), screenHeight: 1032.0), .hidden)
    }

    /// A real keyboard is always measured, so it never covers the input bar; a hide that still reports an
    /// on-screen frame is left to the frame-change notification.
    func test_tablet_realKeyboard_isMeasured() {
        let keyboard = CGRect(x: 0.0, y: 1032.0 - 491.0, width: 1376.0, height: 491.0)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: true, deviceType: .tablet, endFrame: keyboard, screenHeight: 1032.0), .measure)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: true, deviceType: .tablet, endFrame: CGRect(x: 0.0, y: 952.0, width: 1376.0, height: 80.0), screenHeight: 1032.0), .measure)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willHide, isRegularWidth: true, deviceType: .tablet, endFrame: keyboard, screenHeight: 1032.0), .keep)
    }

    func test_phone_isUpstream() {
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: false, deviceType: .phone, endFrame: .zero, screenHeight: 874.0), .measure)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: false, deviceType: .phone, endFrame: CGRect(x: 0.0, y: 538.0, width: 402.0, height: 336.0), screenHeight: 874.0), .measure)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willHide, isRegularWidth: false, deviceType: .phone, endFrame: .zero, screenHeight: 874.0), .keep)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willHide, isRegularWidth: false, deviceType: .phone, endFrame: CGRect(x: 0.0, y: 874.0, width: 402.0, height: 336.0), screenHeight: 874.0), .keep)
    }

    /// iPhone Duo unfolded in landscape is regular width but a phone: upstream ignores an empty frame there, and a
    /// hide is left to the frame-change notification. The tablet rules must not reach it.
    func test_regularWidthPhone_isUpstream() {
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: true, deviceType: .phone, endFrame: .zero, screenHeight: 669.0), .keep)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: true, deviceType: .phone, endFrame: CGRect(x: 0.0, y: 400.0, width: 951.0, height: 269.0), screenHeight: 669.0), .measure)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willHide, isRegularWidth: true, deviceType: .phone, endFrame: .zero, screenHeight: 669.0), .keep)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willHide, isRegularWidth: true, deviceType: .phone, endFrame: CGRect(x: 0.0, y: 669.0, width: 951.0, height: 269.0), screenHeight: 669.0), .keep)
    }

    /// A compact-width iPad window (Slide Over, a narrow Stage Manager window) is laid out as a phone: upstream.
    func test_compactTabletWindow_isUpstream() {
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willChangeFrame, isRegularWidth: false, deviceType: .tablet, endFrame: .zero, screenHeight: 1032.0), .measure)
        XCTAssertEqual(windowKeyboardNotificationDecision(kind: .willHide, isRegularWidth: false, deviceType: .tablet, endFrame: .zero, screenHeight: 1032.0), .keep)
    }

    // MARK: Keyboard orientation

    /// The chat pane of a landscape split view on the iPad Pro 13" (918 x 1032) is taller than wide; the keyboard
    /// is still the landscape one.
    func test_tablet_landscapeSplitPane_usesLandscapeKeyboard() {
        XCTAssertTrue(layoutKeyboardIsLandscape(size: CGSize(width: 918.0, height: 1032.0), deviceType: .tablet, interfaceOrientation: .landscapeLeft, windowSize: CGSize(width: 1376.0, height: 1032.0)))
        XCTAssertTrue(layoutKeyboardIsLandscape(size: CGSize(width: 918.0, height: 1032.0), deviceType: .tablet, interfaceOrientation: nil, windowSize: CGSize(width: 1376.0, height: 1032.0)))
        XCTAssertFalse(layoutKeyboardIsLandscape(size: CGSize(width: 712.0, height: 1376.0), deviceType: .tablet, interfaceOrientation: .portrait, windowSize: CGSize(width: 1032.0, height: 1376.0)))
        // A portrait-shaped Stage Manager window on a landscape screen: the keyboard follows the screen.
        XCTAssertTrue(layoutKeyboardIsLandscape(size: CGSize(width: 700.0, height: 900.0), deviceType: .tablet, interfaceOrientation: .landscapeRight, windowSize: CGSize(width: 700.0, height: 900.0)))
        // No window: the pane decides.
        XCTAssertFalse(layoutKeyboardIsLandscape(size: CGSize(width: 918.0, height: 1032.0), deviceType: .tablet, interfaceOrientation: nil, windowSize: nil))
    }

    func test_phone_keyboardOrientation_isThePanes() {
        XCTAssertFalse(layoutKeyboardIsLandscape(size: CGSize(width: 402.0, height: 874.0), deviceType: .phone, interfaceOrientation: .landscapeLeft, windowSize: CGSize(width: 874.0, height: 402.0)))
        XCTAssertTrue(layoutKeyboardIsLandscape(size: CGSize(width: 874.0, height: 402.0), deviceType: .phone, interfaceOrientation: .portrait, windowSize: CGSize(width: 402.0, height: 874.0)))
    }

    func test_standardInputHeight_splitPane_matchesLandscapeKeyboard() {
        let pane = self.layout(size: CGSize(width: 918.0, height: 1032.0), widthClass: .regular, deviceMetrics: .iPadPro3rdGen, inputHeight: nil, orientation: .landscapeLeft, windowSize: CGSize(width: 1366.0, height: 1024.0))
        XCTAssertEqual(pane.standardInputHeight, DeviceMetrics.iPadPro3rdGen.standardInputHeight(inLandscape: true))
        let phone = self.layout(size: CGSize(width: 402.0, height: 874.0), widthClass: .compact, deviceMetrics: .iPhone16Pro, inputHeight: nil, orientation: .portrait, windowSize: CGSize(width: 402.0, height: 874.0))
        XCTAssertEqual(phone.standardInputHeight, DeviceMetrics.iPhone16Pro.standardInputHeight(inLandscape: false))
    }

    // MARK: Device profiles

    private func metrics(_ width: CGFloat, _ height: CGFloat, statusBar: CGFloat = 24.0, navigation: CGFloat? = 20.0) -> DeviceMetrics {
        return DeviceMetrics(screenSize: CGSize(width: width, height: height), scale: 2.0, statusBarHeight: statusBar, onScreenNavigationHeight: navigation, modelIdentifier: nil)
    }

    private func assertKnownTablet(_ metrics: DeviceMetrics, file: StaticString = #filePath, line: UInt = #line) {
        if case .unknown = metrics {
            XCTFail("unknown profile \(metrics)", file: file, line: line)
        }
        XCTAssertEqual(metrics.type, .tablet, file: file, line: line)
    }

    /// iPad Pro 13" (M4/M5): the owner's iPad. It was `.unknown`, with the 216pt phone keyboard.
    func test_iPadPro13InchM4_isKnown() {
        let m = self.metrics(1032.0, 1376.0)
        self.assertKnownTablet(m)
        XCTAssertEqual(m.standardInputHeight(inLandscape: true), DeviceMetrics.iPadPro3rdGen.standardInputHeight(inLandscape: true))
        XCTAssertEqual(m.standardInputHeight(inLandscape: false), DeviceMetrics.iPadPro3rdGen.standardInputHeight(inLandscape: false))
        // Landscape screen size reported: the same profile.
        XCTAssertEqual(self.metrics(1376.0, 1032.0), m)
    }

    /// iPad Pro 11" (M4/M5).
    func test_iPadPro11InchM4_isKnown() {
        let m = self.metrics(834.0, 1210.0)
        self.assertKnownTablet(m)
        XCTAssertEqual(m.standardInputHeight(inLandscape: true), DeviceMetrics.iPadPro11Inch.standardInputHeight(inLandscape: true))
    }

    /// iPad Air 11" and iPad (10th gen, A16).
    func test_iPadAir11Inch_isKnown() {
        let m = self.metrics(820.0, 1180.0)
        self.assertKnownTablet(m)
        XCTAssertEqual(m.standardInputHeight(inLandscape: true), DeviceMetrics.iPadPro11Inch.standardInputHeight(inLandscape: true))
    }

    /// A tablet without a profile gets an iPad keyboard, not the 216pt phone one.
    func test_unknownTablet_usesIPadKeyboard() {
        let m = self.metrics(900.0, 1300.0)
        XCTAssertEqual(m.type, .tablet)
        XCTAssertEqual(m.standardInputHeight(inLandscape: true), DeviceMetrics.iPadPro11Inch.standardInputHeight(inLandscape: true))
        XCTAssertEqual(m.standardInputHeight(inLandscape: false), DeviceMetrics.iPadPro11Inch.standardInputHeight(inLandscape: false))
    }

    /// A phone without a profile keeps the upstream fallback.
    func test_unknownPhone_isUpstream() {
        let m = self.metrics(500.0, 1000.0, statusBar: 54.0)
        XCTAssertEqual(m.type, .phone)
        XCTAssertEqual(m.keyboardHeight(inLandscape: true), 216.0)
    }

    func test_iPadMinis_areTablets() {
        XCTAssertEqual(DeviceMetrics.iPadMini.type, .tablet)
        XCTAssertEqual(DeviceMetrics.iPadMini6thGen.type, .tablet)
    }

    func test_phoneProfiles_unchanged() {
        XCTAssertEqual(DeviceMetrics.iPhone16Pro.type, .phone)
        XCTAssertEqual(DeviceMetrics.iPhoneDuo.type, .phone)
        XCTAssertEqual(DeviceMetrics(screenSize: CGSize(width: 402.0, height: 874.0), scale: 3.0, statusBarHeight: 54.0, onScreenNavigationHeight: 34.0, modelIdentifier: "iPhone17,1"), .iPhone16Pro)
    }

    // MARK: Floating bottom panels

    /// A hardware keyboard's shortcuts bar (about 50-80pt) is drawn across the bottom, so the tab bar and the edit
    /// toolbar rise above it, as upstream. (The ~80pt bar of the chat's sticker mode is no longer shown at all:
    /// `ChatInputAssistantSuppressor`.)
    func test_regular_shortcutsBar_raises() {
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, inputHeight: 70.0)), 78.0)
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, inputHeight: 100.0)), 108.0)
    }

    /// A Stage Manager window that a real keyboard overlaps by only 60pt reports 60pt: the bar still clears it.
    func test_regular_partialKeyboardOverlap_raises() {
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 458.0, height: 900.0), widthClass: .regular, inputHeight: 60.0)), 68.0)
    }

    func test_regular_realKeyboard_raises() {
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, inputHeight: 420.0)), 428.0)
    }

    func test_regular_noKeyboard() {
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, inputHeight: nil)), 20.0)
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, bottomInset: 0.0, inputHeight: nil)), 8.0)
    }

    /// Compact width is upstream: the input height is already in the insets.
    func test_compact_isUpstream() {
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 402.0, height: 874.0), widthClass: .compact, deviceMetrics: .iPhone16Pro, inputHeight: 336.0)), 20.0)
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 402.0, height: 874.0), widthClass: .compact, deviceMetrics: .iPhone16Pro, inputHeight: 80.0)), 20.0)
        XCTAssertEqual(floatingBottomPanelsInset(layout: self.layout(size: CGSize(width: 402.0, height: 874.0), widthClass: .compact, deviceMetrics: .iPhone16Pro, bottomInset: 0.0, inputHeight: nil)), 8.0)
    }

    // MARK: Sticker panel's bottom bar

    /// iPhone (bar 34 + 20 + 20 = 74pt, or 54pt without a home indicator): the upstream frame.
    func test_mediaPanelBar_phone_isUpstream() {
        XCTAssertEqual(mediaPanelBottomBarEdgeEffectFrame(barSize: CGSize(width: 402.0, height: 74.0), defaultHeight: 80.0), CGRect(x: 0.0, y: -6.0, width: 402.0, height: 80.0))
        XCTAssertEqual(mediaPanelBottomBarEdgeEffectFrame(barSize: CGSize(width: 375.0, height: 54.0), defaultHeight: 80.0), CGRect(x: 0.0, y: -26.0, width: 375.0, height: 80.0))
    }

    /// iPhone before iOS 26 (34pt home-indicator inset: 34 + 34 + 20 = 88pt), and iPhone in landscape: upstream too.
    func test_mediaPanelBar_olderPhone_isUpstream() {
        XCTAssertEqual(mediaPanelBottomBarEdgeEffectFrame(barSize: CGSize(width: 402.0, height: 88.0), defaultHeight: 80.0), CGRect(x: 0.0, y: 8.0, width: 402.0, height: 80.0))
        XCTAssertEqual(mediaPanelBottomBarEdgeEffectFrame(barSize: CGSize(width: 874.0, height: 75.0), defaultHeight: 80.0), CGRect(x: 0.0, y: -5.0, width: 874.0, height: 80.0))
    }

    /// iPad with the bar lifted (34 + 95 + 20 = 149pt): the fade still starts just above the switch, as on iPhone,
    /// and reaches the bottom, so the switch has a background and the grid does not show behind it.
    func test_mediaPanelBar_lifted_coversTheSwitch() {
        let frame = mediaPanelBottomBarEdgeEffectFrame(barSize: CGSize(width: 918.0, height: 149.0), defaultHeight: 80.0)
        XCTAssertEqual(frame.minY, -6.0)
        XCTAssertEqual(frame.maxY, 149.0)
        XCTAssertEqual(frame.width, 918.0)
    }

    // MARK: Media panel height

    private func standard(_ metrics: DeviceMetrics, landscape: Bool) -> CGFloat {
        return metrics.standardInputHeight(inLandscape: landscape)
    }

    /// The owner's case: 13" iPad landscape, 1032pt tall, standard 491pt (48%): now 40%.
    func test_mediaPanel_ipad13Landscape_takesFortyPercent() {
        let height = tabletMediaPanelHeight(standardHeight: self.standard(.iPadPro13InchM4, landscape: true), containerHeight: 1032.0, keyboardHeight: nil, deviceType: .tablet)
        XCTAssertEqual(height, 412.8, accuracy: 0.001)
        XCTAssertLessThan(height, 491.0)
    }

    /// Portrait: 40% of 1376pt is 550pt, more than the standard 398pt, so the standard stays.
    func test_mediaPanel_ipad13Portrait_keepsStandard() {
        let std = self.standard(.iPadPro13InchM4, landscape: false)
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: std, containerHeight: 1376.0, keyboardHeight: nil, deviceType: .tablet), std)
    }

    /// A known keyboard height is a ceiling.
    func test_mediaPanel_keyboardHeightIsACeiling() {
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 491.0, containerHeight: 1032.0, keyboardHeight: 350.0, deviceType: .tablet), 350.0)
        // A taller keyboard does not raise the panel past 40%.
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 491.0, containerHeight: 1032.0, keyboardHeight: 460.0, deviceType: .tablet), 412.8, accuracy: 0.001)
    }

    /// An unknown (nil) or zero keyboard height is ignored.
    func test_mediaPanel_unknownKeyboardIsIgnored() {
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 491.0, containerHeight: 1032.0, keyboardHeight: 0.0, deviceType: .tablet), 412.8, accuracy: 0.001)
    }

    /// A short Split View or Stage Manager window: the minimum keeps the grid usable.
    func test_mediaPanel_shortWindow_keepsMinimum() {
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 418.0, containerHeight: 520.0, keyboardHeight: nil, deviceType: .tablet), 280.0)
        // Even a small keyboard height does not push it under the minimum.
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 418.0, containerHeight: 1032.0, keyboardHeight: 200.0, deviceType: .tablet), 280.0)
    }

    /// The minimum never exceeds the standard height (and so never grows the panel).
    func test_mediaPanel_neverTallerThanStandard() {
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 250.0, containerHeight: 500.0, keyboardHeight: nil, deviceType: .tablet), 250.0)
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 300.0, containerHeight: 2000.0, keyboardHeight: nil, deviceType: .tablet), 300.0)
    }

    /// Degenerate container: upstream.
    func test_mediaPanel_zeroContainer_isUpstream() {
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 400.0, containerHeight: 0.0, keyboardHeight: nil, deviceType: .tablet), 400.0)
    }

    /// iPhone is untouched, in portrait and landscape, whatever the arguments.
    func test_mediaPanel_phone_isUpstream() {
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 336.0, containerHeight: 874.0, keyboardHeight: nil, deviceType: .phone), 336.0)
        XCTAssertEqual(tabletMediaPanelHeight(standardHeight: 209.0, containerHeight: 402.0, keyboardHeight: 100.0, deviceType: .phone), 209.0)
    }

    // MARK: Media panel switcher

    func test_switcher_tablet_isLargerThanPhone() {
        let tablet = mediaPanelSwitcherMetrics(deviceType: .tablet)
        let phone = mediaPanelSwitcherMetrics(deviceType: .phone)
        XCTAssertEqual(tablet.fontSize, 17.0)
        XCTAssertGreaterThan(tablet.itemHeight, phone.itemHeight)
        XCTAssertGreaterThan(tablet.textInset, phone.textInset)
        XCTAssertGreaterThan(tablet.rowHeight, tablet.itemHeight)
        // Touch targets: at least 44pt tall row on iPad.
        XCTAssertGreaterThanOrEqual(tablet.rowHeight, 44.0)
    }

    func test_switcher_phone_isUpstream() {
        XCTAssertEqual(mediaPanelSwitcherMetrics(deviceType: .phone), MediaPanelSwitcherMetrics(fontSize: 14.0, itemHeight: 28.0, textInset: 12.0, rowHeight: 40.0, barIntrinsicHeight: 34.0))
    }
}
