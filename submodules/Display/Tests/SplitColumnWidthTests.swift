import XCTest
import UIKit
@testable import Display

/// The resizable chat-list column (`SplitColumnWidth.swift`). Window sizes are the owner's iPad Pro 13" (M4/M5)
/// full screen (1376×1032), the 11" iPad Pro (1210×834), an iPad mini in portrait (744×1133), a window just
/// above the compact threshold (700) and iPhone Duo's inner screen (951×669).
final class SplitColumnWidthTests: XCTestCase {
    private let pro13Landscape = CGSize(width: 1376.0, height: 1032.0)
    private let pro13Portrait = CGSize(width: 1032.0, height: 1376.0)
    private let pro11Landscape = CGSize(width: 1210.0, height: 834.0)
    private let duoInnerLandscape = CGSize(width: 951.0, height: 669.0)

    // MARK: Range

    func test_range_13InchLandscape_is320To60Percent() {
        XCTAssertEqual(SplitColumnWidth.range(containerWidth: 1376.0), 320.0 ... 825.0)
    }

    func test_range_13InchPortrait_leavesTheChat424() {
        XCTAssertEqual(SplitColumnWidth.range(containerWidth: 1032.0), 320.0 ... 608.0)
    }

    func test_range_11InchLandscape_isCappedAt60Percent() {
        XCTAssertEqual(SplitColumnWidth.range(containerWidth: 1210.0), 320.0 ... 726.0)
    }

    func test_range_narrowWindows_haveNoChoice() {
        XCTAssertNil(SplitColumnWidth.range(containerWidth: 744.0))
        XCTAssertNil(SplitColumnWidth.range(containerWidth: 700.0))
        XCTAssertEqual(SplitColumnWidth.range(containerWidth: 768.0), 320.0 ... 344.0)
    }

    // MARK: Width for a preference

    func test_noPreference_isTheUpstreamDefault() {
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 1376.0, preferred: nil), 458.0)
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 1032.0, preferred: nil), 344.0)
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 834.0, preferred: nil), 320.0)
    }

    func test_preferenceInRange_isUsed() {
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 1376.0, preferred: 600.0), 600.0)
    }

    func test_preference_isClampedToTheRange() {
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 1376.0, preferred: 1000.0), 825.0)
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 1376.0, preferred: 200.0), 320.0)
    }

    func test_preference_isIgnoredWithoutARange() {
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 700.0, preferred: 600.0), 320.0)
    }

    func test_stageManagerShrinkAndGrow_restoresTheRememberedWidth() {
        let preferred: CGFloat = 700.0
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 1000.0, preferred: preferred), 576.0)
        XCTAssertEqual(SplitColumnWidth.masterWidth(containerWidth: 1376.0, preferred: preferred), 700.0)
    }

    func test_splitMasterWidth_usesThePreference() {
        XCTAssertEqual(splitMasterWidth(containerSize: self.pro13Landscape, division: nil, preferredWidth: 600.0), 600.0)
        XCTAssertEqual(splitMasterWidth(containerSize: self.pro13Portrait, division: nil, preferredWidth: 700.0), 608.0)
    }

    func test_splitMasterWidth_foldWinsOverAPreference() {
        let fold = CGRect(x: 455.5, y: 0.0, width: 40.0, height: 669.0)
        XCTAssertEqual(splitMasterWidth(containerSize: self.duoInnerLandscape, division: fold, preferredWidth: 500.0), floorToScreenPixels(475.5))
    }

    // MARK: Snapping

    func test_snapTargets_13InchLandscape() {
        XCTAssertEqual(SplitColumnWidth.snapTargets(containerWidth: 1376.0), [320.0, 375.0, 458.0, 688.0])
    }

    func test_snapTargets_dropThoseOutOfRange() {
        // 1032 portrait: the default third is the minimum's 344, half is 516.
        XCTAssertEqual(SplitColumnWidth.snapTargets(containerWidth: 1032.0), [320.0, 344.0, 375.0, 516.0])
        // 768: only 320 and 344 fit, and the default third is 320.
        XCTAssertEqual(SplitColumnWidth.snapTargets(containerWidth: 768.0), [320.0])
        XCTAssertEqual(SplitColumnWidth.snapTargets(containerWidth: 700.0), [])
    }

    func test_snapped_nearATarget_landsOnIt() {
        XCTAssertEqual(SplitColumnWidth.snapped(380.0, containerWidth: 1376.0).width, 375.0)
        XCTAssertEqual(SplitColumnWidth.snapped(380.0, containerWidth: 1376.0).target, 375.0)
        XCTAssertEqual(SplitColumnWidth.snapped(450.0, containerWidth: 1376.0).width, 458.0)
        XCTAssertEqual(SplitColumnWidth.snapped(697.0, containerWidth: 1376.0).width, 688.0)
    }

    func test_snapped_awayFromTargets_staysPut() {
        let result = SplitColumnWidth.snapped(400.0, containerWidth: 1376.0)
        XCTAssertEqual(result.width, 400.0)
        XCTAssertNil(result.target)
    }

    // MARK: Drag

    func test_drag_followsTheFinger() {
        let result = SplitColumnWidth.dragged(startWidth: 458.0, translation: 142.0, containerWidth: 1376.0)
        XCTAssertEqual(result.width, 600.0)
        XCTAssertNil(result.target)
    }

    func test_drag_stopsAtTheLimits() {
        XCTAssertEqual(SplitColumnWidth.dragged(startWidth: 458.0, translation: 1000.0, containerWidth: 1376.0).width, 825.0)
        let narrow = SplitColumnWidth.dragged(startWidth: 458.0, translation: -500.0, containerWidth: 1376.0)
        XCTAssertEqual(narrow.width, 320.0)
        XCTAssertEqual(narrow.target, 320.0)
    }

    func test_drag_snaps() {
        XCTAssertEqual(SplitColumnWidth.dragged(startWidth: 458.0, translation: 233.0, containerWidth: 1376.0).width, 688.0)
    }

    func test_drag_withoutARange_keepsTheDefault() {
        XCTAssertEqual(SplitColumnWidth.dragged(startWidth: 320.0, translation: 100.0, containerWidth: 700.0).width, 320.0)
    }

    // MARK: Accessibility

    func test_adjusted_stepsBy40WithinRange() {
        XCTAssertEqual(SplitColumnWidth.adjusted(current: 458.0, steps: 1, containerWidth: 1376.0), 498.0)
        XCTAssertEqual(SplitColumnWidth.adjusted(current: 458.0, steps: -1, containerWidth: 1376.0), 418.0)
        XCTAssertEqual(SplitColumnWidth.adjusted(current: 810.0, steps: 1, containerWidth: 1376.0), 825.0)
        XCTAssertEqual(SplitColumnWidth.adjusted(current: 330.0, steps: -1, containerWidth: 1376.0), 320.0)
    }

    // MARK: When it is resizable

    func test_isResizable_tabletWithRoom() {
        XCTAssertTrue(SplitColumnWidth.isResizable(isTablet: true, containerSize: self.pro13Landscape, division: nil))
        XCTAssertTrue(SplitColumnWidth.isResizable(isTablet: true, containerSize: self.pro11Landscape, division: nil))
        XCTAssertTrue(SplitColumnWidth.isResizable(isTablet: true, containerSize: self.pro13Portrait, division: nil))
    }

    func test_isResizable_notOnPhones() {
        XCTAssertFalse(SplitColumnWidth.isResizable(isTablet: false, containerSize: self.duoInnerLandscape, division: nil))
        XCTAssertFalse(SplitColumnWidth.isResizable(isTablet: false, containerSize: self.pro13Landscape, division: nil))
    }

    func test_isResizable_notWithoutRoomOrWithAFold() {
        XCTAssertFalse(SplitColumnWidth.isResizable(isTablet: true, containerSize: CGSize(width: 744.0, height: 1133.0), division: nil))
        let fold = CGRect(x: 668.0, y: 0.0, width: 40.0, height: 1032.0)
        XCTAssertFalse(SplitColumnWidth.isResizable(isTablet: true, containerSize: self.pro13Landscape, division: fold))
    }

    // MARK: Shape

    func test_shape_followsTheWindow() {
        XCTAssertEqual(SplitColumnShape(containerSize: self.pro13Landscape), .landscape)
        XCTAssertEqual(SplitColumnShape(containerSize: self.pro13Portrait), .portrait)
        XCTAssertEqual(SplitColumnShape(containerSize: CGSize(width: 900.0, height: 900.0)), .portrait)
    }

    // MARK: Store

    private func makeDefaults() -> UserDefaults {
        let name = "SplitColumnWidthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        self.addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    func test_store_isEmptyAtFirst() {
        let store = SplitColumnWidthStore(defaults: self.makeDefaults())
        XCTAssertNil(store.preferredWidth(for: .landscape))
        XCTAssertNil(store.preferredWidth(for: .portrait))
    }

    func test_store_keepsOneWidthPerShape_andPersistsIt() {
        let defaults = self.makeDefaults()
        let store = SplitColumnWidthStore(defaults: defaults)
        store.commit(600.0, for: .landscape)
        store.commit(400.0, for: .portrait)
        XCTAssertEqual(store.preferredWidth(for: .landscape), 600.0)
        XCTAssertEqual(store.preferredWidth(containerSize: self.pro13Portrait), 400.0)

        let reloaded = SplitColumnWidthStore(defaults: defaults)
        XCTAssertEqual(reloaded.preferredWidth(for: .landscape), 600.0)
        XCTAssertEqual(reloaded.preferredWidth(for: .portrait), 400.0)
    }

    func test_store_liveWidthWinsButIsNotPersisted() {
        let defaults = self.makeDefaults()
        let store = SplitColumnWidthStore(defaults: defaults)
        store.commit(600.0, for: .landscape)
        store.setLive(650.0, for: .landscape)
        XCTAssertEqual(store.preferredWidth(for: .landscape), 650.0)
        XCTAssertEqual(SplitColumnWidthStore(defaults: defaults).preferredWidth(for: .landscape), 600.0)

        store.cancelLive(for: .landscape)
        XCTAssertEqual(store.preferredWidth(for: .landscape), 600.0)

        store.setLive(700.0, for: .landscape)
        store.commit(700.0, for: .landscape)
        XCTAssertEqual(SplitColumnWidthStore(defaults: defaults).preferredWidth(for: .landscape), 700.0)
    }

    func test_store_resetForgetsOneShape() {
        let defaults = self.makeDefaults()
        let store = SplitColumnWidthStore(defaults: defaults)
        store.commit(600.0, for: .landscape)
        store.commit(400.0, for: .portrait)
        store.reset(for: .landscape)
        XCTAssertNil(store.preferredWidth(for: .landscape))
        XCTAssertEqual(store.preferredWidth(for: .portrait), 400.0)
        XCTAssertNil(SplitColumnWidthStore(defaults: defaults).preferredWidth(for: .landscape))
    }

    func test_store_ignoresGarbage() {
        let defaults = self.makeDefaults()
        defaults.set(["landscape": "wide", "portrait": -5.0, "other": 400.0], forKey: SplitColumnWidthStore.defaultsKey)
        let store = SplitColumnWidthStore(defaults: defaults)
        XCTAssertNil(store.preferredWidth(for: .landscape))
        XCTAssertNil(store.preferredWidth(for: .portrait))
    }
}
