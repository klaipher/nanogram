import XCTest
import UIKit
import Display
import SwitchNode
import ItemListUI

final class ItemListSwitchItemMetricsTests: XCTestCase {
    // iPhone 17 Pro Max portrait, a grouped (blocks) row: the screen where long Debug Settings titles
    // ran under the switch.
    private let rowWidth: CGFloat = 440.0
    private let rowLeftInset: CGFloat = 20.0
    private let rowRightInset: CGFloat = 20.0
    private var titleLeftInset: CGFloat { 16.0 + self.rowLeftInset }

    private func gapBetweenTitleAndSwitch(style: ItemListSwitchControlStyle, iconInset: CGFloat = 0.0) -> CGFloat {
        let leftInset = self.titleLeftInset + iconInset
        let titleMaxX = leftInset + ItemListSwitchItemMetrics.titleMaxWidth(rowWidth: self.rowWidth, leftInset: leftInset, rightInset: self.rowRightInset, switchStyle: style)
        let switchMinX = ItemListSwitchItemMetrics.switchMinX(rowWidth: self.rowWidth, rightInset: self.rowRightInset, switchWidth: style.switchWidth)
        return switchMinX - titleMaxX
    }

    func testGlassSwitchLeavesSpacingAfterLongestTitle() {
        // The iOS 26 switch is 63 pt wide; reserving 64 pt for it let the title run 14 pt under it.
        XCTAssertGreaterThanOrEqual(self.gapBetweenTitleAndSwitch(style: .glass), 8.0)
        XCTAssertGreaterThanOrEqual(self.gapBetweenTitleAndSwitch(style: .glass, iconInset: 43.0), 8.0)
    }

    func testLegacySwitchLeavesSpacingAfterLongestTitle() {
        // 51 pt switch + 15 pt trailing inset is 66 pt: 64 pt let the title touch it.
        XCTAssertGreaterThanOrEqual(self.gapBetweenTitleAndSwitch(style: .legacy), 8.0)
    }

    func testSpacingIsTheSameForBothSwitches() {
        XCTAssertEqual(self.gapBetweenTitleAndSwitch(style: .glass), ItemListSwitchItemMetrics.titleToSwitchSpacing)
        XCTAssertEqual(self.gapBetweenTitleAndSwitch(style: .legacy), ItemListSwitchItemMetrics.titleToSwitchSpacing)
    }

    func testTitleWidthNeverNegative() {
        XCTAssertEqual(ItemListSwitchItemMetrics.titleMaxWidth(rowWidth: 50.0, leftInset: 36.0, rightInset: 20.0, switchStyle: .glass), 0.0)
    }

    func testCurrentStyleMatchesMeasuredSwitchWidth() {
        let systemSwitch = UISwitch()
        systemSwitch.sizeToFit()
        XCTAssertEqual(systemSwitch.bounds.width, ItemListSwitchControlStyle.current.switchWidth)

        let switchNode = SwitchNode()
        guard let switchView = switchNode.view as? UISwitch else {
            return XCTFail("SwitchNode's view is not a UISwitch")
        }
        switchView.sizeToFit()
        XCTAssertEqual(switchView.bounds.width, ItemListSwitchControlStyle.current.switchWidth)

        let iconSwitchNode = IconSwitchNode()
        guard let iconSwitchView = iconSwitchNode.view as? UISwitch else {
            return XCTFail("IconSwitchNode's view is not a UISwitch")
        }
        iconSwitchView.sizeToFit()
        XCTAssertEqual(iconSwitchView.bounds.width, ItemListSwitchControlStyle.current.switchWidth)
    }

    func testCurrentStyleFollowsTheOS() {
        if #available(iOS 26.0, *) {
            XCTAssertEqual(ItemListSwitchControlStyle.current, .glass)
        } else {
            XCTAssertEqual(ItemListSwitchControlStyle.current, .legacy)
        }
    }
}
