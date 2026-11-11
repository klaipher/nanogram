import XCTest
@testable import Display

final class NavigationHitchWindowTests: XCTestCase {
    func testBeginThenEndClosesTheWindow() {
        var window = NavigationHitchWindow()
        XCTAssertNil(window.begin("backSwipe:Chat"))
        XCTAssertTrue(window.isOpen)
        XCTAssertEqual(window.end(), "backSwipe:Chat")
        XCTAssertFalse(window.isOpen)
    }

    func testCommitOrCancelOfASwipeLeavesNothingOpen() {
        for _ in 0 ..< 2 {
            var window = NavigationHitchWindow()
            _ = window.begin("backSwipe:Chat")
            _ = window.end()
            XCTAssertFalse(window.isOpen)
            XCTAssertNil(window.end(), "a second ending has nothing to close")
        }
    }

    func testBeginningAnotherWindowReturnsTheOpenOneToClose() {
        var window = NavigationHitchWindow()
        _ = window.begin("backSwipe:Chat")
        XCTAssertEqual(window.begin("navPush:Profile"), "backSwipe:Chat")
        XCTAssertEqual(window.end(), "navPush:Profile")
    }
}
