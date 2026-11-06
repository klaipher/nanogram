import XCTest
import UIKit
@testable import GlassBackgroundComponent

final class GlassDebugGroupsTests: XCTestCase {
    override func tearDown() {
        GlassDebugGroups.setDisabledMask(0)
        super.tearDown()
    }

    /// The bits are stored in ExperimentalUISettings.glassDebugDisabledGroups (1, 2, 4); changing them would reinterpret saved settings.
    func testTheBitsAreTheSavedSettingsContract() {
        XCTAssertEqual(GlassDebugGroup.navigationBar.rawValue, 1)
        XCTAssertEqual(GlassDebugGroup.inputPanel.rawValue, 2)
        XCTAssertEqual(GlassDebugGroup.floatingButtons.rawValue, 4)
    }

    func testMaskArithmetic() {
        XCTAssertEqual(GlassDebugGroups.mask(of: []), 0)
        XCTAssertEqual(GlassDebugGroups.mask(of: [.navigationBar, .floatingButtons]), 5)
        XCTAssertEqual(GlassDebugGroups.groups(in: 6), [.inputPanel, .floatingButtons])
        XCTAssertEqual(GlassDebugGroups.mask(0, setting: .inputPanel, disabled: true), 2)
        XCTAssertEqual(GlassDebugGroups.mask(7, setting: .inputPanel, disabled: false), 5)
        XCTAssertEqual(GlassDebugGroups.mask(2, setting: .inputPanel, disabled: true), 2)
    }

    func testNothingIsOffByDefault() {
        XCTAssertFalse(GlassDebugGroups.anyDisabled)
        for group in GlassDebugGroup.allCases {
            XCTAssertFalse(GlassDebugGroups.isDisabled(group))
        }
    }

    func testUnknownBitsAreDropped() {
        GlassDebugGroups.setDisabledMask(0x7FFF_FFF8 | GlassDebugGroup.inputPanel.rawValue)
        XCTAssertEqual(GlassDebugGroups.disabledMask, 2)
    }

    func testChangeIsAnnouncedOnlyWhenItChanges() {
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: GlassEnvironment.didChangeNotification, object: nil, queue: nil, using: { _ in count += 1 })
        defer { NotificationCenter.default.removeObserver(token) }
        GlassDebugGroups.setDisabledMask(1)
        GlassDebugGroups.setDisabledMask(1)
        GlassDebugGroups.setDisabledMask(0)
        XCTAssertEqual(count, 2)
    }

    /// A glass view finds its group through the container above it; one outside every group is never switched off.
    func testOnlyViewsInASwitchedOffGroupAreAffected() {
        let navigation = GlassBackgroundContainerView()
        navigation.debugGroup = .navigationBar
        let input = GlassBackgroundContainerView()
        input.debugGroup = .inputPanel
        let inNavigation = GlassBackgroundView()
        let inInput = GlassBackgroundView()
        let alone = GlassBackgroundView()
        navigation.contentView.addSubview(inNavigation)
        input.contentView.addSubview(inInput)
        for view in [inNavigation, inInput, alone] {
            view.update(size: CGSize(width: 40.0, height: 40.0), cornerRadius: 20.0, isDark: false, tintColor: .init(kind: .panel), transition: .immediate)
        }
        GlassDebugGroups.setDisabledMask(GlassDebugGroup.navigationBar.rawValue)
        XCTAssertTrue(inNavigation.isSwitchedOffForTesting)
        XCTAssertFalse(inInput.isSwitchedOffForTesting)
        XCTAssertFalse(alone.isSwitchedOffForTesting)
        GlassDebugGroups.setDisabledMask(0)
        XCTAssertFalse(inNavigation.isSwitchedOffForTesting)
    }
}
