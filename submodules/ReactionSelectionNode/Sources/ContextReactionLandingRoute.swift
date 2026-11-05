import Foundation

/// How a reaction chosen in the message context menu reaches the message.
public enum ContextReactionLandingRoute: Equatable {
    /// The picker's emoji flies from the menu to the message and the effect plays in the menu.
    case flightFromMenu
    /// The menu fades and the chat plays the effect itself, as for a double tap.
    case standaloneInChat
    /// Nothing to land on: just close the menu.
    case dismissOnly
}

/// With the keyboard up the menu is hosted in the keyboard window (another scene than the chat), where the
/// flight and the effect never show, and the message's reaction stays hidden until a 2 s timer. When the menu
/// is not in the chat's window the chat plays the effect in its own window instead.
///
/// Compare against the CHAT's window, not the target view's: while the menu is open the message bubble (and the
/// reaction pill inside it) is extracted into the menu, so the target view is in the menu's window too.
public func contextReactionLandingRoute(hasTargetView: Bool, menuWindow: ObjectIdentifier?, chatWindow: ObjectIdentifier?, hasStandaloneItem: Bool) -> ContextReactionLandingRoute {
    guard hasTargetView else {
        return .dismissOnly
    }
    guard let chatWindow, hasStandaloneItem, menuWindow != chatWindow else {
        // Same window (keyboard closed), chat off screen, or no item to play: the upstream flight.
        return .flightFromMenu
    }
    // Menu in the keyboard window, or off screen.
    return .standaloneInChat
}
