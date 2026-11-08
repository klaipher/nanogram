import XCTest
import Postbox
import TelegramCore
@testable import NotificationServiceExtensionLib

final class NoneToneHapticTests: XCTestCase {
    private let now: Int32 = 1_800_000_000

    private func global(sound: PeerMessageSound, enabled: Bool = true) -> MessageNotificationSettings {
        return MessageNotificationSettings(enabled: enabled, displayPreviews: true, sound: sound, storySettings: .default)
    }

    private func peer(sound: PeerMessageSound = .default, mute: PeerMuteState = .default) -> TelegramPeerNotificationSettings {
        return TelegramPeerNotificationSettings(muteState: mute, messageSound: sound, displayPreviews: .default, storySettings: .default)
    }

    private func replacement(
        current: String? = nil,
        silent: Bool = false,
        title: String? = "Name",
        body: String? = "Text",
        category: String? = "m",
        peers: [TelegramPeerNotificationSettings] = [],
        defaults: MessageNotificationSettings
    ) -> String? {
        return NoneToneHaptic.replacementSound(currentSound: current, isSilent: silent, title: title, subtitle: nil, body: body, category: category, peerSettings: peers, defaults: defaults, now: self.now)
    }

    func testGlobalNoneInEveryCategoryGivesTheHapticSound() {
        let set = GlobalNotificationSettingsSet(
            privateChats: global(sound: .none),
            groupChats: global(sound: .none),
            channels: global(sound: .none),
            reactionSettings: .default,
            contactsJoined: true
        )
        for category in [NoneToneHaptic.Category.privateChat, .group, .channel] {
            XCTAssertEqual(self.replacement(defaults: NoneToneHaptic.defaults(for: category, global: set)), NoneToneHaptic.soundName)
        }
    }

    func testCategoryUsesItsOwnGlobalTone() {
        let set = GlobalNotificationSettingsSet(
            privateChats: global(sound: .none),
            groupChats: global(sound: .default),
            channels: global(sound: .default),
            reactionSettings: .default,
            contactsJoined: true
        )
        XCTAssertEqual(self.replacement(defaults: NoneToneHaptic.defaults(for: .privateChat, global: set)), NoneToneHaptic.soundName)
        XCTAssertNil(self.replacement(defaults: NoneToneHaptic.defaults(for: .group, global: set)))
        XCTAssertNil(self.replacement(defaults: NoneToneHaptic.defaults(for: .channel, global: set)))
    }

    func testCategoryFromPeerNamespace() {
        XCTAssertEqual(NoneToneHaptic.category(peerNamespace: Namespaces.Peer.CloudUser, isBroadcastChannel: nil), .privateChat)
        XCTAssertEqual(NoneToneHaptic.category(peerNamespace: Namespaces.Peer.CloudGroup, isBroadcastChannel: nil), .group)
        XCTAssertEqual(NoneToneHaptic.category(peerNamespace: Namespaces.Peer.CloudChannel, isBroadcastChannel: true), .channel)
        XCTAssertEqual(NoneToneHaptic.category(peerNamespace: Namespaces.Peer.CloudChannel, isBroadcastChannel: false), .group)
        XCTAssertNil(NoneToneHaptic.category(peerNamespace: Namespaces.Peer.CloudChannel, isBroadcastChannel: nil))
        XCTAssertNil(NoneToneHaptic.category(peerNamespace: Namespaces.Peer.SecretChat, isBroadcastChannel: nil))
    }

    func testChatToneNoneOverridesAudibleGlobalTone() {
        XCTAssertEqual(self.replacement(peers: [self.peer(sound: .none)], defaults: self.global(sound: .default)), NoneToneHaptic.soundName)
    }

    func testChatToneOverridesGlobalNone() {
        XCTAssertNil(self.replacement(peers: [self.peer(sound: .cloud(fileId: 5))], defaults: self.global(sound: .none)))
        XCTAssertEqual(self.replacement(peers: [self.peer(sound: .default)], defaults: self.global(sound: .none)), NoneToneHaptic.soundName)
    }

    func testTopicToneWinsOverChatTone() {
        let topic = self.peer(sound: .none)
        let chat = self.peer(sound: .cloud(fileId: 7))
        XCTAssertEqual(self.replacement(peers: [topic, chat], defaults: self.global(sound: .default)), NoneToneHaptic.soundName)
        // The chat alone has an audible tone; the topic ahead of it does not override it with default.
        XCTAssertNil(self.replacement(peers: [self.peer(sound: .default), chat], defaults: self.global(sound: .none)))
    }

    func testMutedChatStaysWithoutSound() {
        let none = self.global(sound: .none)
        XCTAssertNil(self.replacement(peers: [self.peer(mute: .muted(until: Int32.max))], defaults: none))
        XCTAssertNil(self.replacement(peers: [self.peer(mute: .muted(until: self.now + 60))], defaults: none))
        XCTAssertNil(self.replacement(defaults: self.global(sound: .none, enabled: false)))
    }

    func testExpiredMuteAndExplicitUnmuteNotify() {
        XCTAssertEqual(self.replacement(peers: [self.peer(mute: .muted(until: self.now - 1))], defaults: self.global(sound: .none)), NoneToneHaptic.soundName)
        XCTAssertEqual(self.replacement(peers: [self.peer(mute: .unmuted)], defaults: self.global(sound: .none, enabled: false)), NoneToneHaptic.soundName)
    }

    func testSilentMessageStaysWithoutSound() {
        XCTAssertNil(self.replacement(silent: true, defaults: self.global(sound: .none)))
    }

    func testAnySoundAlreadyOnThePushIsKept() {
        XCTAssertNil(self.replacement(current: "default", defaults: self.global(sound: .none)))
        XCTAssertNil(self.replacement(current: "0.m4a", defaults: self.global(sound: .none)))
        XCTAssertNil(self.replacement(current: "123.mp3", defaults: self.global(sound: .none)))
        // An empty sound value counts as no sound.
        XCTAssertEqual(self.replacement(current: "", defaults: self.global(sound: .none)), NoneToneHaptic.soundName)
    }

    func testOtherTonesAreUnchanged() {
        for sound in [PeerMessageSound.default, .cloud(fileId: 1), .bundledModern(id: 3), .bundledClassic(id: 2)] {
            XCTAssertNil(self.replacement(defaults: self.global(sound: sound)))
        }
    }

    func testNonAlertingAndUncoveredPushesAreUnchanged() {
        let none = self.global(sound: .none)
        XCTAssertNil(self.replacement(title: nil, body: nil, defaults: none))
        XCTAssertNil(self.replacement(title: "", body: "", defaults: none))
        XCTAssertNil(self.replacement(category: "t", defaults: none))
        XCTAssertNil(self.replacement(category: "st", defaults: none))
        XCTAssertNil(self.replacement(category: "str", defaults: none))
        XCTAssertEqual(self.replacement(category: "gm", defaults: none), NoneToneHaptic.soundName)
    }

    func testResolveMatchesCoreRules() {
        let resolved = NoneToneHaptic.resolve(list: [self.peer(mute: .default), self.peer(sound: .none, mute: .unmuted)], defaults: self.global(sound: .default, enabled: false), now: self.now)
        XCTAssertTrue(resolved.notify)
        XCTAssertEqual(resolved.tone, .none)
    }
}
