import Foundation
import XCTest
@testable import ReactionSelectionNode

// With the keyboard open the context menu lives in the keyboard window, and a reaction chosen in it showed
// its badge but never the flight or the effect. The chat plays the effect itself when the windows differ.
final class ContextReactionLandingRouteTests: XCTestCase {
    private let windowA = ObjectIdentifier(NSObject())
    private let windowB = ObjectIdentifier(NSObject())

    func testSameWindowKeepsTheFlight() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: windowA, targetWindow: windowA, hasStandaloneItem: true), .flightFromMenu)
    }

    func testDifferentWindowsPlayInChat() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: windowA, targetWindow: windowB, hasStandaloneItem: true), .standaloneInChat)
    }

    func testMenuWithoutWindowPlaysInChat() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: nil, targetWindow: windowB, hasStandaloneItem: true), .standaloneInChat)
    }

    func testDifferentWindowsWithoutItemKeepTheFlight() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: windowA, targetWindow: windowB, hasStandaloneItem: false), .flightFromMenu)
    }

    func testMissingTargetOnlyDismisses() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: false, menuWindow: windowA, targetWindow: windowA, hasStandaloneItem: true), .dismissOnly)
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: windowA, targetWindow: nil, hasStandaloneItem: true), .dismissOnly)
    }
}
