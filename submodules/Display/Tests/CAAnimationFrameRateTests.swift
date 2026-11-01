import XCTest
import UIKit
@testable import Display

/// Frame-rate hints that `makeAnimation` and friends put on Core Animation animations.
/// Apple's ProMotion guidance: 80-120 Hz only for high-impact motion; alpha or color transitions,
/// small movements and progress spinners need no higher rate
/// (https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays).
@available(iOS 15.0, *)
final class CAAnimationFrameRateTests: XCTestCase {
    private let promotion: Float = 120.0

    func testMotionKeepsFullRateOnProMotion() {
        for keyPath in ["position", "position.x", "bounds", "transform", "transform.scale", "sublayerTransform", "bounds.origin.y"] {
            let range = animationFrameRateRange(keyPath: keyPath, repeatCount: 0.0, maximumFramesPerSecond: self.promotion)
            XCTAssertEqual(range, CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0), keyPath)
        }
    }

    func testOpacityAndColorUseSystemDefault() {
        for keyPath in ["opacity", "backgroundColor", "borderColor", "shadowColor", "fillColor", "strokeColor", "foregroundColor", "shadowOpacity"] {
            XCTAssertNil(animationFrameRateRange(keyPath: keyPath, repeatCount: 0.0, maximumFramesPerSecond: self.promotion), keyPath)
        }
    }

    func testInfiniteLoopIsCappedAt60() {
        let range = animationFrameRateRange(keyPath: "position.x", repeatCount: .infinity, maximumFramesPerSecond: self.promotion)
        XCTAssertEqual(range, decorativeLoopFrameRateRange)
        XCTAssertEqual(range?.maximum, 60.0)
    }

    func testNoHintOn60HzScreens() {
        XCTAssertNil(animationFrameRateRange(keyPath: "position", repeatCount: 0.0, maximumFramesPerSecond: 60.0))
        XCTAssertNil(animationFrameRateRange(keyPath: "position", repeatCount: .infinity, maximumFramesPerSecond: 60.0))
    }

    /// `makeAnimation` cannot see a repeat count the caller sets afterwards (every shimmer does this),
    /// so the caller marks the loop explicitly.
    func testShimmerStyleLoopMarkedAfterCreation() {
        let layer = CALayer()
        let animation = layer.makeAnimation(from: 0.0 as NSNumber, to: 400.0 as NSNumber, keyPath: "position.x", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 1.3, removeOnCompletion: true, additive: true)
        animation.repeatCount = .infinity
        animation.setDecorativeLoopFrameRate(maximumFramesPerSecond: self.promotion)
        XCTAssertEqual(animation.preferredFrameRateRange, decorativeLoopFrameRateRange)

        let other = CABasicAnimation(keyPath: "contentsRect.origin.x")
        other.setDecorativeLoopFrameRate(maximumFramesPerSecond: 60.0)
        XCTAssertEqual(other.preferredFrameRateRange, .default)
    }

    func testGroupAndSpringKeepFullRate() {
        let layer = CALayer()
        let spring = layer.springAnimation(from: 0.0 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.3)
        let maxFps = Float(UIScreen.main.maximumFramesPerSecond)
        if maxFps > 61.0 {
            XCTAssertEqual(spring.preferredFrameRateRange, CAFrameRateRange(minimum: 30.0, maximum: maxFps, preferred: maxFps))
        } else {
            XCTAssertEqual(spring.preferredFrameRateRange, .default)
        }
    }
}
