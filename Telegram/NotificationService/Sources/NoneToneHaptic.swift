import Foundation
import Postbox
import TelegramCore

/// Notification tone "None" must stay inaudible but still vibrate. The server leaves the `sound`
/// key out of the push when the tone is None, and iOS fires the Taptic Engine only for a
/// notification that carries a sound, so the vibration disappeared together with the tone.
/// For a notification that would otherwise alert, the extension substitutes a bundled,
/// practically silent sound; the system then vibrates according to Settings, Sounds & Haptics.
///
/// Only a local lookup tells "tone is None" apart from the other reasons a push has no sound
/// (muted chat, "Send without sound", notifications off), so every input here comes from the
/// account's own settings, resolved the same way `resolveNotificationSettings` does for the
/// in-app path. Nothing is sent to the server.
enum NoneToneHaptic {
    /// In `Telegram/Telegram-iOS/Resources/notifications`, bundled with the app next to `0.m4a`.
    static let soundName = "nanogram-none-haptic.caf"

    enum Category: Equatable {
        case privateChat
        case group
        case channel
    }

    /// The default-settings category of a message push. Channels need to be told apart from
    /// supergroups by the stored peer; `nil` means "unknown", and an unknown peer keeps the
    /// push as it is.
    static func category(peerNamespace: PeerId.Namespace, isBroadcastChannel: Bool?) -> Category? {
        if peerNamespace == Namespaces.Peer.CloudUser || peerNamespace == Namespaces.Peer.SecretChat {
            // Secret chats use the private-chat defaults and the settings of the peer they belong to.
            return .privateChat
        } else if peerNamespace == Namespaces.Peer.CloudGroup {
            return .group
        } else if peerNamespace == Namespaces.Peer.CloudChannel {
            guard let isBroadcastChannel else {
                return nil
            }
            return isBroadcastChannel ? .channel : .group
        } else {
            return nil
        }
    }

    static func defaults(for category: Category, global: GlobalNotificationSettingsSet) -> MessageNotificationSettings {
        switch category {
        case .privateChat:
            return global.privateChats
        case .group:
            return global.groupChats
        case .channel:
            return global.channels
        }
    }

    /// Message reactions (category "t") and stories have their own tones and mute rules and are
    /// not covered. A push the extension handles as a call never reaches this point.
    static func isCandidate(currentSound: String?, isSilent: Bool, title: String?, subtitle: String?, body: String?, category: String?) -> Bool {
        if let currentSound, !currentSound.isEmpty {
            return false
        }
        if isSilent {
            return false
        }
        if category == "t" || category == "st" || category == "str" {
            return false
        }
        let hasText = [title, subtitle, body].contains(where: { !($0 ?? "").isEmpty })
        return hasText
    }

    /// Same resolution as `resolveNotificationSettings` in TelegramCore: the list holds the
    /// most specific settings first (topic, then chat); the first non-default tone wins and
    /// the last mute state in the list that is not "default" decides whether it notifies.
    static func resolve(list: [TelegramPeerNotificationSettings], defaults: MessageNotificationSettings, now: Int32) -> (tone: PeerMessageSound.Id, notify: Bool) {
        var sound = defaults.sound
        var notify = defaults.enabled
        for item in list.reversed() {
            if case .default = item.messageSound {
            } else {
                sound = item.messageSound
            }
            switch item.muteState {
            case .default:
                break
            case .unmuted:
                notify = true
            case let .muted(deadline):
                notify = deadline <= now
            }
        }
        return (sound.id, notify)
    }

    /// The sound name to put on the notification, or `nil` to leave it without sound.
    static func replacementSound(
        currentSound: String?,
        isSilent: Bool,
        title: String?,
        subtitle: String?,
        body: String?,
        category: String?,
        peerSettings: [TelegramPeerNotificationSettings],
        defaults: MessageNotificationSettings,
        now: Int32
    ) -> String? {
        guard isCandidate(currentSound: currentSound, isSilent: isSilent, title: title, subtitle: subtitle, body: body, category: category) else {
            return nil
        }
        let resolved = resolve(list: peerSettings, defaults: defaults, now: now)
        guard resolved.notify, case .none = resolved.tone else {
            return nil
        }
        return soundName
    }
}
