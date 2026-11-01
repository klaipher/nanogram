import XCTest
import QuartzCore
import LegacyComponents

private final class Target: NSObject {
    var value: CGFloat = 0.0
}

/// POP drives the typing dots and download spinners from one display link that ran with no rate hint,
/// so 120 Hz on ProMotion. It now asks for 60 Hz while only forever loops run and keeps the default
/// (full) rate as soon as anything else (gestures, springs, transitions) is animating.
final class POPAnimatorFrameRateTests: XCTestCase {
    private func displayLink() -> CADisplayLink? {
        // POPAnimator is not a public header; reach the shared instance and its link by name.
        guard let animatorClass = NSClassFromString("POPAnimator") else {
            XCTFail("no POPAnimator class")
            return nil
        }
        guard let animator = (animatorClass as AnyObject).perform(NSSelectorFromString("sharedAnimator"))?.takeUnretainedValue() as? NSObject else {
            XCTFail("no shared animator")
            return nil
        }
        // KVC falls back to the `_displayLink` ivar (there is no accessor).
        let value = animator.value(forKey: "displayLink")
        guard let link = value as? CADisplayLink else {
            XCTFail("_displayLink is \(String(describing: value))")
            return nil
        }
        return link
    }

    private func makeAnimation(repeatForever: Bool) -> POPBasicAnimation {
        let animation = POPBasicAnimation()
        animation.property = POPAnimatableProperty.property(withName: "testValue", initializer: { property in
            property?.readBlock = { object, values in
                if let target = object as? Target {
                    values?.pointee = target.value
                }
            }
            property?.writeBlock = { object, values in
                if let target = object as? Target, let values {
                    target.value = values.pointee
                }
            }
            property?.threshold = 0.01
        }) as? POPAnimatableProperty
        animation.fromValue = 0.0 as NSNumber
        animation.toValue = 1.0 as NSNumber
        animation.duration = 2.0
        animation.repeatForever = repeatForever
        return animation
    }

    private func spin() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    func testLoopsAloneRunAt60AndAnythingElseRestoresTheDefault() {
        let loop = Target()
        let transition = Target()

        loop.pop_add(self.makeAnimation(repeatForever: true), forKey: "loop")
        self.spin()
        guard let link = self.displayLink() else {
            XCTFail("no POP display link")
            return
        }
        XCTAssertFalse(link.isPaused)
        XCTAssertEqual(link.preferredFrameRateRange, CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0))

        transition.pop_add(self.makeAnimation(repeatForever: false), forKey: "transition")
        self.spin()
        XCTAssertEqual(link.preferredFrameRateRange, .default)

        transition.pop_removeAnimation(forKey: "transition")
        self.spin()
        XCTAssertEqual(link.preferredFrameRateRange, CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0))

        loop.pop_removeAnimation(forKey: "loop")
        self.spin()
        XCTAssertTrue(link.isPaused)
    }

    func testNonRepeatingAnimationAloneKeepsTheDefault() {
        let target = Target()
        target.pop_add(self.makeAnimation(repeatForever: false), forKey: "once")
        self.spin()
        XCTAssertEqual(self.displayLink()?.preferredFrameRateRange, .default)
        target.pop_removeAnimation(forKey: "once")
        self.spin()
    }
}

