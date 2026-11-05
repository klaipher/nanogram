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

/// With the keyboard up the menu is hosted in the keyboard window (another scene than the message), where the
/// flight and the effect never show, and the message's reaction stays hidden until a 2 s timer. When the menu and
/// the message are not in the same window the chat plays the effect in its own window instead.
public func contextReactionLandingRoute(hasTargetView: Bool, menuWindow: ObjectIdentifier?, targetWindow: ObjectIdentifier?, hasStandaloneItem: Bool) -> ContextReactionLandingRoute {
    guard hasTargetView, targetWindow != nil else {
        return .dismissOnly
    }
    if menuWindow == targetWindow {
        return .flightFromMenu
    }
    // Menu in the keyboard window, or off screen.
    return hasStandaloneItem ? .standaloneInChat : .flightFromMenu
}
