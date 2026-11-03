import XCTest
import UIKit
import Display
import TabBarLayout

final class TabBarChildBottomInsetTests: XCTestCase {
    private func layout(size: CGSize, widthClass: ContainerViewLayoutSizeClass, inputHeight: CGFloat?) -> ContainerViewLayout {
        return ContainerViewLayout(size: size, metrics: LayoutMetrics(widthClass: widthClass, heightClass: widthClass, orientation: nil), deviceMetrics: widthClass == .regular ? .iPadPro3rdGen : .iPhone16Pro, intrinsicInsets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 20.0, right: 0.0), safeInsets: UIEdgeInsets(), reservedCorners: .none, division: nil, additionalInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: inputHeight, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
    }

    /// iPad column: the bar computed 84pt (64pt bar, 20pt above the edge). A tab selected now gets 84pt, not the
    /// estimate built on the assistant bar's height (49 + 80).
    func test_usesTheBarsInsetForTheSameLayout() {
        let column = self.layout(size: CGSize(width: 458.0, height: 1032.0), widthClass: .regular, inputHeight: 80.0)
        XCTAssertEqual(tabBarChildBottomInset(layout: column, computedLayout: column, computedBottomInset: 84.0), 84.0)
    }

    /// iPhone keeps the upstream estimate even when the bar has an inset for this layout: that inset can include
    /// the previous tab's search-keyboard lift.
    func test_phone_isTheUpstreamEstimate() {
        let phone = self.layout(size: CGSize(width: 402.0, height: 874.0), widthClass: .compact, inputHeight: nil)
        XCTAssertEqual(tabBarChildBottomInset(layout: phone, computedLayout: phone, computedBottomInset: 84.0), 69.0)
        XCTAssertEqual(tabBarChildBottomInset(layout: phone, computedLayout: phone, computedBottomInset: 400.0), 69.0)
    }

    /// Before the bar has been laid out for this layout: the upstream estimate.
    func test_otherLayout_isTheUpstreamEstimate() {
        let phone = self.layout(size: CGSize(width: 402.0, height: 874.0), widthClass: .compact, inputHeight: nil)
        let rotated = self.layout(size: CGSize(width: 874.0, height: 402.0), widthClass: .compact, inputHeight: nil)
        XCTAssertEqual(tabBarChildBottomInset(layout: phone, computedLayout: rotated, computedBottomInset: 84.0), 69.0)
        XCTAssertEqual(tabBarChildBottomInset(layout: phone, computedLayout: nil, computedBottomInset: nil), 69.0)
        XCTAssertEqual(tabBarChildBottomInset(layout: phone, computedLayout: phone, computedBottomInset: nil), 69.0)
    }
}
