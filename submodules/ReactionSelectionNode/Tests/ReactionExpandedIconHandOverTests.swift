import Foundation
import XCTest
import AsyncDisplayKit
@testable import ReactionSelectionNode

// A sent reaction's picker item switches to its larger animation, which flies into the message's
// button and stands in for the button's icon. That animation is read from the reaction's file; while
// the file is still downloading it draws nothing. The item faded its drawn still icon out at once,
// so the reaction, and the button it stood in for, were empty until the download finished.
final class ReactionExpandedIconHandOverTests: XCTestCase {
    func testStillIconStaysUntilTheExpandedAnimationHasAFrame() {
        let handOver = ReactionExpandedIconHandOver()
        let stillIcon = ASDisplayNode()
        var removed = false

        handOver.fadeOutWhenExpandedAnimationStarts(stillIcon, duration: 0.2, completion: {
            removed = true
        })
        XCTAssertEqual(stillIcon.alpha, 1.0, "the still icon stays while the larger animation has drawn nothing")
        XCTAssertTrue(handOver.hasPendingFadeOut)

        handOver.expandedAnimationStarted()
        XCTAssertEqual(stillIcon.alpha, 0.0, "the first frame of the larger animation fades it out")
        XCTAssertFalse(handOver.hasPendingFadeOut)
        _ = removed
    }

    func testAnAnimationThatNeverStartsLeavesTheIcon() {
        let handOver = ReactionExpandedIconHandOver()
        let stillIcon = ASDisplayNode()
        handOver.fadeOutWhenExpandedAnimationStarts(stillIcon, duration: 0.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(stillIcon.alpha, 1.0, "no timeout: an icon is better than an empty reaction")
    }

    func testAfterTheStartIconsFadeAtOnce() {
        let handOver = ReactionExpandedIconHandOver()
        handOver.expandedAnimationStarted()
        let stillIcon = ASDisplayNode()
        handOver.fadeOutWhenExpandedAnimationStarts(stillIcon, duration: 0.2)
        XCTAssertEqual(stillIcon.alpha, 0.0)
    }

    func testStartIsReportedOnce() {
        let handOver = ReactionExpandedIconHandOver()
        let stillIcon = ASDisplayNode()
        var completions = 0
        handOver.fadeOutWhenExpandedAnimationStarts(stillIcon, duration: 0.0, completion: {
            completions += 1
        })
        handOver.expandedAnimationStarted()
        handOver.expandedAnimationStarted()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertLessThanOrEqual(completions, 1)
    }

    // The appear animation can end while the larger animation still has no frame: the still icon
    // then takes its place instead of leaving the item empty.
    func testStaticIconShowsAfterTheAppearAnimationUntilTheExpandedAnimationStarts() {
        let handOver = ReactionExpandedIconHandOver()
        XCTAssertTrue(handOver.showsStaticIconAfterAppearAnimation(hasExpandedAnimation: false))
        XCTAssertTrue(handOver.showsStaticIconAfterAppearAnimation(hasExpandedAnimation: true))
        handOver.expandedAnimationStarted()
        XCTAssertFalse(handOver.showsStaticIconAfterAppearAnimation(hasExpandedAnimation: true))
        XCTAssertTrue(handOver.showsStaticIconAfterAppearAnimation(hasExpandedAnimation: false))
    }
}
