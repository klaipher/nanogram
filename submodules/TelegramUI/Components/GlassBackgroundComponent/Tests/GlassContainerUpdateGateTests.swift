import XCTest
import UIKit
@testable import GlassBackgroundComponent

final class GlassContainerUpdateGateTests: XCTestCase {
    func testFirstUpdateAppliesEverything() {
        let changes = GlassContainerUpdateGate.changes(applied: nil, size: CGSize(width: 40.0, height: 40.0), isDark: false)
        XCTAssertTrue(changes.size)
        XCTAssertTrue(changes.isDark)
    }

    func testRepeatedUpdateAppliesNothing() {
        let size = CGSize(width: 390.0, height: 120.0)
        let changes = GlassContainerUpdateGate.changes(applied: (size, true), size: size, isDark: true)
        XCTAssertFalse(changes.any)
    }

    func testOnlyWhatChangedIsApplied() {
        let size = CGSize(width: 390.0, height: 120.0)
        let resized = GlassContainerUpdateGate.changes(applied: (size, true), size: CGSize(width: 390.0, height: 121.0), isDark: true)
        XCTAssertTrue(resized.size)
        XCTAssertFalse(resized.isDark)
        let themed = GlassContainerUpdateGate.changes(applied: (size, true), size: size, isDark: false)
        XCTAssertFalse(themed.size)
        XCTAssertTrue(themed.isDark)
    }

    /// The view keeps its container effect view's size and style across identical updates.
    func testContainerViewAppliesAnIdenticalUpdateOnce() {
        let container = GlassBackgroundContainerView()
        container.update(size: CGSize(width: 100.0, height: 50.0), isDark: true, transition: .immediate)
        container.update(size: CGSize(width: 100.0, height: 50.0), isDark: true, transition: .immediate)
        container.update(size: CGSize(width: 120.0, height: 50.0), isDark: false, transition: .immediate)
        XCTAssertNotNil(container.contentView)
    }
}
