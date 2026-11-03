import Foundation

/// Whether a sent reaction's effect animation can play when the reaction lands.
enum ReactionEffectAvailability: Equatable {
    /// The reaction has no effect.
    case none
    /// The effect is on the device (downloaded, or bundled).
    case local
    /// The effect is still to be downloaded: nothing plays until it is.
    case notLocal
}

/// Whether the picker hands a sent reaction to the message's button as soon as it lands, rather
/// than keeping its own node in the button until the 2 s timer.
///
/// - Parameters:
///   - base: the reaction's own choice (custom reactions switch at once, built-in ones wait).
///   - isExpanded: the long-press (large) reaction, which finishes through the timer.
///   - effect: whether the effect can play now. A missing one plays nothing until it downloads
///     (effects are prefetched with the available reactions, so this is a fresh install, a cleared
///     cache or a new reaction), so the reaction goes to the button at once.
func reactionSwitchesToInlineImmediately(base: Bool, isExpanded: Bool, effect: ReactionEffectAvailability) -> Bool {
    if base {
        return true
    }
    if isExpanded {
        return false
    }
    return effect == .notLocal
}
