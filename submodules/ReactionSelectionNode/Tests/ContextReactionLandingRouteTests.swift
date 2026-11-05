import Foundation
import XCTest
@testable import ReactionSelectionNode

// With the keyboard open the context menu lives in the keyboard window, and a reaction chosen in it showed
// its badge but never the flight or the effect. The chat plays the effect itself when the menu is not in the
// chat's window.
final class ContextReactionLandingRouteTests: XCTestCase {
    // Kept alive: identifiers of freed objects can collide when the memory is reused.
    private let objectA = NSObject()
    private let objectB = NSObject()
    private var windowA: ObjectIdentifier { ObjectIdentifier(self.objectA) }
    private var windowB: ObjectIdentifier { ObjectIdentifier(self.objectB) }

    func testSameWindowKeepsTheFlight() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: windowA, chatWindow: windowA, hasStandaloneItem: true), .flightFromMenu)
    }

    func testMenuInAnotherWindowPlaysInChat() {
        XCTAssertNotEqual(windowA, windowB)
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: windowA, chatWindow: windowB, hasStandaloneItem: true), .standaloneInChat)
    }

    func testMenuWithoutWindowPlaysInChat() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: nil, chatWindow: windowB, hasStandaloneItem: true), .standaloneInChat)
    }

    func testMenuInAnotherWindowWithoutItemKeepsTheFlight() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: windowA, chatWindow: windowB, hasStandaloneItem: false), .flightFromMenu)
    }

    func testChatWithoutWindowKeepsTheFlight() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: true, menuWindow: windowA, chatWindow: nil, hasStandaloneItem: true), .flightFromMenu)
    }

    func testMissingTargetOnlyDismisses() {
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: false, menuWindow: windowA, chatWindow: windowB, hasStandaloneItem: true), .dismissOnly)
        XCTAssertEqual(contextReactionLandingRoute(hasTargetView: false, menuWindow: windowA, chatWindow: windowA, hasStandaloneItem: true), .dismissOnly)
    }
}
