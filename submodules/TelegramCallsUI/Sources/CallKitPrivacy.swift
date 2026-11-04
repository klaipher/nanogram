import Foundation

/// What a call leaves behind outside the app: an entry in the system's Phone Recents (and the iCloud call history
/// it syncs to) and a Siri suggestion donated for an outgoing call.
///
/// The user's choice is mirrored into `UserDefaults` because a call can be reported (a VoIP push on a cold start)
/// before the shared account settings have loaded, and the CallKit provider has to know it when it is created.
enum CallKitPrivacy {
    static let showCallsInRecentsKey = "nanogram.callKit.showCallsInRecents"

    static func showCallsInRecents(defaults: UserDefaults = .standard) -> Bool {
        return defaults.object(forKey: self.showCallsInRecentsKey) as? Bool ?? true
    }

    static func storeShowCallsInRecents(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: self.showCallsInRecentsKey)
    }

    /// Message donations are skipped while a passcode is set; an outgoing call names the same people and follows
    /// the same rule. Hiding calls from Recents hides them from Siri suggestions too.
    static func shouldDonateOutgoingCall(isUnprotected: Bool, showCallsInRecents: Bool) -> Bool {
        return isUnprotected && showCallsInRecents
    }
}
