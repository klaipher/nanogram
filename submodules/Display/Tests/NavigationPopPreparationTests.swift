import XCTest
@testable import Display

final class NavigationPopPreparationTests: XCTestCase {
    private typealias Preparation = NavigationPopPreparation<Int>

    private func canPrepare(isEnabled: Bool = true, isInFocus: Bool = true, hasTransition: Bool = false, hasInteractivePop: Bool = false, hasPendingChild: Bool = false, controllerCount: Int = 2) -> Bool {
        return Preparation.canPrepare(isEnabled: isEnabled, isInFocus: isInFocus, hasTransition: hasTransition, hasInteractivePop: hasInteractivePop, hasPendingChild: hasPendingChild, controllerCount: controllerCount)
    }

    func testSwitchIsOffByDefault() {
        XCTAssertFalse(NavigationPopPreparationSettings.isEnabled)
    }

    func testPreparesOnlyAnIdleTopScreenWithAScreenBeneath() {
        XCTAssertTrue(self.canPrepare())
        XCTAssertFalse(self.canPrepare(isEnabled: false))
        XCTAssertFalse(self.canPrepare(isInFocus: false))
        XCTAssertFalse(self.canPrepare(hasTransition: true))
        XCTAssertFalse(self.canPrepare(hasInteractivePop: true))
        XCTAssertFalse(self.canPrepare(hasPendingChild: true))
        XCTAssertFalse(self.canPrepare(controllerCount: 1))
        XCTAssertFalse(self.canPrepare(controllerCount: 0))
    }

    func testPreparedForTheSameScreenAndLayoutOnly() {
        let a = NSObject()
        let b = NSObject()
        var preparation = Preparation()
        XCTAssertFalse(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 1))
        preparation.markPrepared(controller: ObjectIdentifier(a), layout: 1)
        XCTAssertTrue(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 1))
        XCTAssertFalse(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 2), "a new layout needs the screen laid out again")
        XCTAssertFalse(preparation.isPrepared(controller: ObjectIdentifier(b), layout: 1), "only one screen is held")
    }

    func testMarkingAnotherScreenReplacesTheFirstAndResetForgetsIt() {
        let a = NSObject()
        let b = NSObject()
        var preparation = Preparation()
        preparation.markPrepared(controller: ObjectIdentifier(a), layout: 1)
        preparation.markPrepared(controller: ObjectIdentifier(b), layout: 1)
        XCTAssertFalse(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 1))
        XCTAssertTrue(preparation.isPrepared(controller: ObjectIdentifier(b), layout: 1))
        XCTAssertEqual(preparation.reset(), ObjectIdentifier(b))
        XCTAssertFalse(preparation.isPrepared(controller: ObjectIdentifier(b), layout: 1))
        XCTAssertNil(preparation.reset())
    }

    func testIdleDelayIsShortOfASecond() {
        XCTAssertGreaterThan(Preparation.idleDelay, 0.0)
        XCTAssertLessThan(Preparation.idleDelay, 1.0)
    }

    func testContentChangeMakesThePreparedScreenUnprepared() {
        let a = NSObject()
        let b = NSObject()
        var preparation = Preparation()
        preparation.markPrepared(controller: ObjectIdentifier(a), layout: 1)
        preparation.noteContentChange(controller: ObjectIdentifier(b))
        XCTAssertTrue(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 1), "another screen's change is not ours")
        preparation.noteContentChange(controller: ObjectIdentifier(a))
        XCTAssertFalse(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 1))
        preparation.markPrepared(controller: ObjectIdentifier(a), layout: 1)
        XCTAssertTrue(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 1), "preparing again draws the change")
    }

    func testContentChangeWithNothingPreparedIsIgnoredAndResetClearsIt() {
        let a = NSObject()
        var preparation = Preparation()
        preparation.noteContentChange(controller: ObjectIdentifier(a))
        preparation.markPrepared(controller: ObjectIdentifier(a), layout: 1)
        XCTAssertTrue(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 1))
        preparation.noteContentChange(controller: ObjectIdentifier(a))
        preparation.reset()
        preparation.markPrepared(controller: ObjectIdentifier(a), layout: 1)
        XCTAssertTrue(preparation.isPrepared(controller: ObjectIdentifier(a), layout: 1))
    }
}
