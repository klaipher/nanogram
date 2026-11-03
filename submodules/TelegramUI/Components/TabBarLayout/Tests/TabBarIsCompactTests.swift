import XCTest
import UIKit
import Display
import TabBarLayout

final class TabBarIsCompactTests: XCTestCase {
    private func layout(size: CGSize, widthClass: ContainerViewLayoutSizeClass, deviceMetrics: DeviceMetrics) -> ContainerViewLayout {
        return ContainerViewLayout(size: size, metrics: LayoutMetrics(widthClass: widthClass, heightClass: widthClass, orientation: nil), deviceMetrics: deviceMetrics, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), reservedCorners: .none, division: nil, additionalInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
    }

    // Master-detail: the tab bar sits in the master pane of a regular-width layout.

    func test_unfoldedDuoMasterPane_compact() {
        XCTAssertTrue(tabBarIsCompact(layout: self.layout(size: CGSize(width: 320.0, height: 669.0), widthClass: .regular, deviceMetrics: .iPhoneDuo), sidePlacement: nil))
    }

    // iPad: the bar spans the chat-list column with labels, as on iPhone, whatever the column's width
    // (the owner's 13" in landscape: 458pt; portrait: 320pt).

    func test_iPadMasterPane_fullWidth() {
        XCTAssertFalse(tabBarIsCompact(layout: self.layout(size: CGSize(width: 375.0, height: 1194.0), widthClass: .regular, deviceMetrics: .iPadPro11Inch), sidePlacement: nil))
        XCTAssertFalse(tabBarIsCompact(layout: self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, deviceMetrics: .iPadPro3rdGen), sidePlacement: nil))
        XCTAssertFalse(tabBarIsCompact(layout: self.layout(size: CGSize(width: 320.0, height: 1376.0), widthClass: .regular, deviceMetrics: .iPadPro3rdGen), sidePlacement: nil))
    }

    func test_unknownTabletMasterPane_fullWidth() {
        let metrics = DeviceMetrics.unknown(screenSize: CGSize(width: 1032.0, height: 1376.0), statusBarHeight: 24.0, onScreenNavigationHeight: 20.0, screenCornerRadius: 0.0)
        XCTAssertFalse(tabBarIsCompact(layout: self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, deviceMetrics: metrics), sidePlacement: nil))
    }

    /// The full-width bar lays out as on iPhone: the items share the column (less 20pt margins).
    func test_iPadMasterPane_itemsShareTheColumn() {
        let layout = self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, deviceMetrics: .iPadPro3rdGen)
        let isCompact = tabBarIsCompact(layout: layout, sidePlacement: nil)
        let items = tabBarItemsLayout(axis: .horizontal, isCompact: isCompact, unboundItemWidths: [60.0, 60.0, 60.0, 60.0], availableLength: 458.0 - 40.0)
        // Each item's length is floored to the screen pixel (1x in the test process): up to 1pt per item short.
        XCTAssertEqual(items.size.width, 418.0, accuracy: 4.0)
        XCTAssertGreaterThan(items.size.width, 400.0)
    }

    // Single pane: the bar keeps its labels.

    func test_unfoldedDuoPortrait_regular() {
        XCTAssertFalse(tabBarIsCompact(layout: self.layout(size: CGSize(width: 669.0, height: 951.0), widthClass: .compact, deviceMetrics: .iPhoneDuo), sidePlacement: nil))
    }

    func test_iPhone_regular() {
        XCTAssertFalse(tabBarIsCompact(layout: self.layout(size: CGSize(width: 402.0, height: 874.0), widthClass: .compact, deviceMetrics: .iPhone16Pro), sidePlacement: nil))
    }

    // The vertical bar is always compact.

    func test_sidePlacement_compact() {
        let placement = TabBarSidePlacement(edge: .right, frame: CGRect(x: 396.0, y: 424.0, width: 48.0, height: 232.0))
        XCTAssertTrue(tabBarIsCompact(layout: self.layout(size: CGSize(width: 466.0, height: 678.0), widthClass: .compact, deviceMetrics: .iPhoneDuo), sidePlacement: placement))
    }
}
