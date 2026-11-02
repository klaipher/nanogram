import XCTest
import UIKit
@testable import VideoMessageCameraScreen

/// Pins the circle's loading shimmer against layout passes.
///
/// `update(size:)` runs on every layout of the round-video screen, and while recording that is every 0.09 s
/// (each duration update). It used to compare the circle's size with the 200 pt gradient strip's, which never
/// matched, so each pass removed and restarted the sweep: the band only ever got as far as the circle's left
/// edge, a glow blinking there ~11 times a second (measured in a screen recording after pause and resume, where
/// the shimmer was also left visible).
final class LoadingEffectViewTests: XCTestCase {
    private func sweep(_ view: LoadingEffectView) -> CAAnimation? {
        // backgroundView is the first subview; its sweep is the "shimmer" animation.
        return view.subviews.first?.layer.animation(forKey: "shimmer")
    }

    func testLayoutWithTheSameSizeKeepsTheRunningSweep() {
        let view = LoadingEffectView(effectAlpha: 0.1, borderAlpha: 0.25, duration: 1.0)
        let size = CGSize(width: 250.0, height: 250.0)
        view.frame = CGRect(origin: .zero, size: size)

        view.update(size: size, transition: .immediate)
        guard let first = self.sweep(view) else {
            XCTFail("no sweep after the first layout")
            return
        }
        for _ in 0 ..< 5 {
            view.update(size: size, transition: .immediate)
        }
        XCTAssertTrue(self.sweep(view) === first, "a layout with an unchanged size restarted the sweep")
    }

    func testANewSizeRestartsTheSweepForThatSize() {
        let view = LoadingEffectView(effectAlpha: 0.1, borderAlpha: 0.25, duration: 1.0)
        view.update(size: CGSize(width: 250.0, height: 250.0), transition: .immediate)
        let first = self.sweep(view)

        view.update(size: CGSize(width: 300.0, height: 300.0), transition: .immediate)
        let second = self.sweep(view)
        XCTAssertNotNil(second)
        XCTAssertFalse(second === first)
    }
}
