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

    // The long-press and stars reactions fly a view of their own into the button. When the button's
    // layer has drawn nothing yet, that view moves into the button, keeping its size and scale, and
    // stands in there until the first frame (the long-press path used to fly in a snapshot of the
    // empty layer instead, and then showed the empty layer).
    func testAStandInFlownInIsAdoptedUntilTheFirstFrame() {
        let view = self.makeView()
        let elsewhere = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 300.0, height: 300.0))
        let standIn = UIView(frame: CGRect(x: 100.0, y: 100.0, width: 120.0, height: 120.0))
        standIn.layer.transform = CATransform3DMakeScale(0.25, 0.25, 1.0)
        elsewhere.addSubview(standIn)
        standIn.layer.add(CABasicAnimation(keyPath: "opacity"), forKey: "opacity")

        view.handOffAnimation(from: standIn, adoptingAt: CGPoint(x: 10.0, y: 10.0))
        XCTAssertTrue(standIn.superview === view)
        XCTAssertEqual(standIn.center, CGPoint(x: 10.0, y: 10.0))
        XCTAssertEqual(standIn.bounds.size, CGSize(width: 120.0, height: 120.0))
        XCTAssertTrue(CATransform3DEqualToTransform(standIn.layer.transform, CATransform3DMakeScale(0.25, 0.25, 1.0)))
        XCTAssertNil(standIn.layer.animationKeys(), "the flight's animations end with it")
        XCTAssertTrue(view.isAnimationHidden)

        view.contentGate.setHasContent(true)
        XCTAssertNil(standIn.superview)
        XCTAssertFalse(view.isAnimationHidden)
    }

    func testAFlownInStandInIsNotAdoptedWhenTheLayerHasAFrame() {
        let view = self.makeView()
        view.contentGate.setHasContent(true)
        let elsewhere = UIView()
        let standIn = UIView()
        elsewhere.addSubview(standIn)

        view.handOffAnimation(from: standIn, adoptingAt: CGPoint(x: 10.0, y: 10.0))
        XCTAssertNil(standIn.superview, "nothing to stand in for: the view goes")
        XCTAssertFalse(view.isAnimationHidden)
    }

    // The button makes a new animation layer when its file resolves or when it pauses. A new layer
    // made while a stand-in hides the animation must start hidden too, or it shows (empty) on top
    // of the hand-off.
    func testANewAnimationLayerFollowsTheHiddenState() {
        let view = self.makeView()
        view.updateIsAnimationHidden(isAnimationHidden: true, transition: .immediate)
        let hiddenLayer = CALayer()
        view.addAnimationLayer(hiddenLayer)
        XCTAssertTrue(hiddenLayer.superlayer === view.layer)
        XCTAssertEqual(hiddenLayer.opacity, 0.0)

        view.updateIsAnimationHidden(isAnimationHidden: false, transition: .immediate)
        let shownLayer = CALayer()
        shownLayer.opacity = 0.0
        view.addAnimationLayer(shownLayer)
        XCTAssertEqual(shownLayer.opacity, 1.0)
    }
}
