import Foundation
import UIKit
import XCTest
@testable import ReactionButtonListComponent

// Every path that puts a reaction into a message's button (the picker, a double tap's quick
// reaction, the long-press reaction, the stars reaction) shows its own view in the button while the
// button's animation layer loads its first frame, then reveals the layer and removes that view.
// Revealing without waiting showed an empty button, a brand-new one (a reaction just added) above
// all. The hand-off is the button's: it waits for the first frame.
final class ReactionIconViewHandOffTests: XCTestCase {
    private func makeView() -> ReactionIconView {
        return ReactionIconView(frame: CGRect(x: 0.0, y: 0.0, width: 20.0, height: 20.0))
    }

    func testStandInStaysUntilTheFirstFrame() {
        let view = self.makeView()
        let standIn = UIView()
        view.addSubview(standIn)

        view.handOffAnimation(from: standIn)
        XCTAssertTrue(standIn.superview === view, "the stand-in stays while the layer has no frame")
        XCTAssertTrue(view.isAnimationHidden, "the empty layer stays hidden")

        view.contentGate.setHasContent(true)
        XCTAssertNil(standIn.superview, "the first frame removes the stand-in")
        XCTAssertFalse(view.isAnimationHidden, "and shows the layer")
    }

    func testHandOffIsImmediateWhenTheLayerHasAFrame() {
        let view = self.makeView()
        view.contentGate.setHasContent(true)
        let standIn = UIView()
        view.addSubview(standIn)
        view.updateIsAnimationHidden(isAnimationHidden: true, transition: .immediate)

        view.handOffAnimation(from: standIn)
        XCTAssertNil(standIn.superview)
        XCTAssertFalse(view.isAnimationHidden)
    }

    func testResetRemovesTheStandIn() {
        let view = self.makeView()
        let standIn = UIView()
        view.addSubview(standIn)
        view.handOffAnimation(from: standIn)

        view.reset()
        XCTAssertNil(standIn.superview)
        XCTAssertFalse(view.isAnimationHidden)
        XCTAssertFalse(view.contentGate.hasPendingWork, "nothing waits for a layer that is gone")
    }

    func testAStandInMovedElsewhereIsLeftAlone() {
        let view = self.makeView()
        let standIn = UIView()
        view.addSubview(standIn)
        view.handOffAnimation(from: standIn)

        let elsewhere = UIView()
        elsewhere.addSubview(standIn)
        view.contentGate.setHasContent(true)
        XCTAssertTrue(standIn.superview === elsewhere)
        XCTAssertFalse(view.isAnimationHidden)
    }
}
