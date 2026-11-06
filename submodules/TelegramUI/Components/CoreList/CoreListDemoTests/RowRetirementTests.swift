import XCTest
@testable import CoreListDemo

/// `CoreVirtualListView.rowRetirementHandler`: the hook a host uses to take over the teardown of rows a scroll rebalance
/// unloaded (deferring their removal, or keeping the views).
final class RowRetirementTests: XCTestCase {
    private func scrollAway(_ fixture: PhysicsListFixture) {
        fixture.simulateFlick(offsetVelocity: 4_000)
        _ = fixture.runUntilSettled(max: 5.0)
    }

    func testWithoutAHandlerUnloadedRowsAreRemovedInTheSameTick() {
        let fixture = PhysicsListFixture(itemCount: 200)
        let initial = Array(fixture.listView.loadedItemViews)
        self.scrollAway(fixture)
        let loaded = Set(fixture.listView.loadedItemViews.map { ObjectIdentifier($0) })
        let gone = initial.filter { !loaded.contains(ObjectIdentifier($0)) }
        XCTAssertFalse(gone.isEmpty, "the flick must unload some of the first rows")
        for view in gone {
            XCTAssertNil(view.superview, "an unloaded row is removed by render() as before")
        }
    }

    func testAHandlerThatDeclinesChangesNothing() {
        let fixture = PhysicsListFixture(itemCount: 200)
        var offered: [UIView] = []
        fixture.listView.rowRetirementHandler = { views in
            offered.append(contentsOf: views)
            return false
        }
        self.scrollAway(fixture)
        XCTAssertFalse(offered.isEmpty, "the handler is offered the unloaded rows")
        for view in offered {
            XCTAssertNil(view.superview)
            XCTAssertFalse(view.isHidden)
        }
    }

    func testTakenOverRowsStayHiddenInTheContainerUntilReleased() {
        let fixture = PhysicsListFixture(itemCount: 200)
        var taken: [UIView & CoreListItemView] = []
        fixture.listView.rowRetirementHandler = { views in
            taken.append(contentsOf: views)
            return true
        }
        self.scrollAway(fixture)
        XCTAssertFalse(taken.isEmpty)
        let loaded = Set(fixture.listView.loadedItemViews.map { ObjectIdentifier($0) })
        for view in taken {
            XCTAssertFalse(loaded.contains(ObjectIdentifier(view)), "a retired row is not in the window")
            XCTAssertTrue(view.isHidden, "a taken-over row is hidden")
            XCTAssertTrue(view.superview === fixture.listView.container, "and no later render() removes it")
        }
        for view in taken {
            fixture.listView.releaseRetiredRow(view)
            XCTAssertFalse(view.isHidden)
            view.removeFromSuperview()
        }
    }

    func testAReleasedRowIsSweptByTheNextRenderLikeAnyStaleRow() {
        let fixture = PhysicsListFixture(itemCount: 200)
        var taken: [UIView & CoreListItemView] = []
        fixture.listView.rowRetirementHandler = { views in
            taken.append(contentsOf: views)
            return true
        }
        self.scrollAway(fixture)
        guard let first = taken.first else {
            XCTFail("nothing was retired")
            return
        }
        fixture.listView.releaseRetiredRow(first)
        fixture.simulateFlick(offsetVelocity: -4_000)
        _ = fixture.runUntilSettled(max: 5.0)
        XCTAssertFalse(first.superview === fixture.listView.container && first.isHidden, "no longer protected")
    }
}
