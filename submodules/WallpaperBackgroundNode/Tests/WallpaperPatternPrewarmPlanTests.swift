import XCTest

final class WallpaperPatternPrewarmPlanTests: XCTestCase {
    func testPhoneChatSizeIsTheScreenInPortrait() {
        XCTAssertEqual(WallpaperPatternPrewarmPlan.chatBackgroundSize(screenSize: CGSize(width: 440.0, height: 956.0), isPhone: true), CGSize(width: 440.0, height: 956.0))
        XCTAssertEqual(WallpaperPatternPrewarmPlan.chatBackgroundSize(screenSize: CGSize(width: 956.0, height: 440.0), isPhone: true), CGSize(width: 440.0, height: 956.0))
    }

    func testNoSizeWhereTheChatSizeIsNotKnownAhead() {
        XCTAssertNil(WallpaperPatternPrewarmPlan.chatBackgroundSize(screenSize: CGSize(width: 1024.0, height: 1366.0), isPhone: false))
        XCTAssertNil(WallpaperPatternPrewarmPlan.chatBackgroundSize(screenSize: .zero, isPhone: true))
        XCTAssertNil(WallpaperPatternPrewarmPlan.chatBackgroundSize(screenSize: CGSize(width: 440.0, height: 0.0), isPhone: true))
        XCTAssertNil(WallpaperPatternPrewarmPlan.chatBackgroundSize(screenSize: CGSize(width: CGFloat.infinity, height: 956.0), isPhone: true))
        XCTAssertNil(WallpaperPatternPrewarmPlan.chatBackgroundSize(screenSize: CGSize(width: CGFloat.nan, height: 956.0), isPhone: true))
    }

    func testRendersOnlyWhenEnabledAndNotCached() {
        XCTAssertTrue(WallpaperPatternPrewarmPlan.shouldRender(isEnabled: true, isAlreadyCached: false))
        XCTAssertFalse(WallpaperPatternPrewarmPlan.shouldRender(isEnabled: true, isAlreadyCached: true))
        XCTAssertFalse(WallpaperPatternPrewarmPlan.shouldRender(isEnabled: false, isAlreadyCached: false))
        XCTAssertFalse(WallpaperPatternPrewarmPlan.shouldRender(isEnabled: false, isAlreadyCached: true))
    }

    func testANewRequestSupersedesTheOneInFlight() {
        var epoch = WallpaperPatternPrewarmEpoch()
        let first = epoch.begin()
        XCTAssertTrue(epoch.isCurrent(first))
        let second = epoch.begin()
        XCTAssertFalse(epoch.isCurrent(first))
        XCTAssertTrue(epoch.isCurrent(second))
    }

    func testMemoryWarningOrCancelDropsTheRenderInFlight() {
        var epoch = WallpaperPatternPrewarmEpoch()
        let token = epoch.begin()
        epoch.invalidate()
        XCTAssertFalse(epoch.isCurrent(token))
        let next = epoch.begin()
        XCTAssertTrue(epoch.isCurrent(next))
    }
}
