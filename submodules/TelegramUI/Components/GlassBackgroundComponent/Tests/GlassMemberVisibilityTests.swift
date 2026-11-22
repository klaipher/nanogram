import XCTest
@testable import GlassBackgroundComponent

final class GlassMemberVisibilityTests: XCTestCase {
    /// A member that was never shown is hidden: its glass must not be on from the start.
    func testNeverShownMemberIsHidden() {
        let visibility = GlassMemberVisibility()
        XCTAssertFalse(visibility.isShown)
    }

    func testHideOfAHiddenMemberChangesNothing() {
        var visibility = GlassMemberVisibility()
        XCTAssertFalse(visibility.hide())
        XCTAssertFalse(visibility.isShown)
    }

    func testShowThenHideReportEachChangeOnce() {
        var visibility = GlassMemberVisibility()
        XCTAssertTrue(visibility.show())
        XCTAssertFalse(visibility.show())
        XCTAssertTrue(visibility.isShown)
        XCTAssertTrue(visibility.hide())
        XCTAssertFalse(visibility.hide())
        XCTAssertFalse(visibility.isShown)
    }

    func testCompletionCommitsHiddenOnlyForACompletedHide() {
        var visibility = GlassMemberVisibility()
        XCTAssertTrue(visibility.show())
        XCTAssertTrue(visibility.hide())
        XCTAssertTrue(visibility.mayCommitHidden(animationCompleted: true))
        // Cancelled by something other than a show: the next reconcile owns it, a cancelled completion commits nothing.
        XCTAssertFalse(visibility.mayCommitHidden(animationCompleted: false))
    }

    /// Hide, then show before the hide finished: the old animation's completion must not hide the shown button.
    func testLateHideCompletionDoesNotHideAShownMember() {
        var visibility = GlassMemberVisibility()
        XCTAssertTrue(visibility.show())
        XCTAssertTrue(visibility.hide())
        XCTAssertTrue(visibility.show())
        XCTAssertFalse(visibility.mayCommitHidden(animationCompleted: true))
        XCTAssertFalse(visibility.mayCommitHidden(animationCompleted: false))
    }

    func testContainerIsVisibleExactlyWhenAMemberIsNotHidden() {
        XCTAssertFalse(GlassMemberVisibility.containerIsVisible(memberIsHidden: []))
        XCTAssertFalse(GlassMemberVisibility.containerIsVisible(memberIsHidden: [true, true, true]))
        XCTAssertTrue(GlassMemberVisibility.containerIsVisible(memberIsHidden: [true, false, true]))
    }

    func testStuckMemberPredicate() {
        XCTAssertTrue(GlassMemberVisibility.isStuckMember(layerOpacity: 0, isHidden: false, hasRunningOpacityAnimation: false, isShown: false))
        // Still fading out: not stuck yet.
        XCTAssertFalse(GlassMemberVisibility.isStuckMember(layerOpacity: 0, isHidden: false, hasRunningOpacityAnimation: true, isShown: false))
        XCTAssertFalse(GlassMemberVisibility.isStuckMember(layerOpacity: 0, isHidden: true, hasRunningOpacityAnimation: false, isShown: false))
        XCTAssertFalse(GlassMemberVisibility.isStuckMember(layerOpacity: 1, isHidden: false, hasRunningOpacityAnimation: false, isShown: true))
        XCTAssertFalse(GlassMemberVisibility.isStuckMember(layerOpacity: 0, isHidden: false, hasRunningOpacityAnimation: false, isShown: true))
    }
}
