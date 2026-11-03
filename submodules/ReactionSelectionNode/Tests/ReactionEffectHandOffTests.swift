import Foundation
import XCTest
@testable import ReactionSelectionNode

// A reaction sent from the picker plays its effect (applicationAnimation, aroundAnimation or
// largeApplicationAnimation) around the message while the picker's node stands in for the button.
// When the effect file is not on the device yet nothing plays until it downloads, and the button
// waited behind the stand-in for the picker's 2 s timer. Then the reaction goes to the button at once.
final class ReactionEffectHandOffTests: XCTestCase {
    func testMissingEffectHandsOffAtOnce() {
        XCTAssertTrue(reactionSwitchesToInlineImmediately(base: false, isExpanded: false, effect: .notLocal))
    }

    func testLocalEffectKeepsTheWait() {
        XCTAssertFalse(reactionSwitchesToInlineImmediately(base: false, isExpanded: false, effect: .local))
        XCTAssertFalse(reactionSwitchesToInlineImmediately(base: false, isExpanded: false, effect: .none))
    }

    func testImmediateStaysImmediate() {
        XCTAssertTrue(reactionSwitchesToInlineImmediately(base: true, isExpanded: false, effect: .local))
        XCTAssertTrue(reactionSwitchesToInlineImmediately(base: true, isExpanded: false, effect: .notLocal))
    }

    // The expanded (long-press) reaction finishes through the 2 s timer, which hands over to the
    // standalone large animation; switching inline there would leave the selection uncompleted.
    func testExpandedReactionKeepsItsPath() {
        XCTAssertFalse(reactionSwitchesToInlineImmediately(base: false, isExpanded: true, effect: .notLocal))
    }
}
