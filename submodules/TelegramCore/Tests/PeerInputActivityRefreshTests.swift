import XCTest
import Postbox
@testable import TelegramCore

final class PeerInputActivityRefreshTests: XCTestCase {
    // Our own typing notice is driven by keystrokes. Re-sending it at most every 4.5 s keeps it under the
    // receivers' display windows (TDLib 5.5 s, Telegram iOS 8 s), like Telegram Desktop, which
    // re-sends its own typing every 5 s. Upstream re-sent it on the first keystroke after 1 s.
    func testOwnTypingIsRefreshedAfterFourAndAHalfSeconds() {
        XCTAssertFalse(peerInputActivityNeedsReissue(previous: .typingText, current: .typingText, elapsed: 1.2, isLocal: true))
        XCTAssertFalse(peerInputActivityNeedsReissue(previous: .typingText, current: .typingText, elapsed: 4.5, isLocal: true))
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .typingText, current: .typingText, elapsed: 4.6, isLocal: true))
    }

    func testIncomingTypingKeepsTheOneSecondRefresh() {
        XCTAssertFalse(peerInputActivityNeedsReissue(previous: .typingText, current: .typingText, elapsed: 0.9, isLocal: false))
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .typingText, current: .typingText, elapsed: 1.2, isLocal: false))
    }

    func testAChangedActivityIsSentAtOnce() {
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .uploadingPhoto(progress: 10), current: .uploadingPhoto(progress: 20), elapsed: 0.1, isLocal: true))
        let messageId = MessageId(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1)), namespace: Namespaces.Message.Cloud, id: 1)
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .interactingWithEmoji(emoticon: "a", messageId: messageId, interaction: nil), current: .interactingWithEmoji(emoticon: "b", messageId: messageId, interaction: nil), elapsed: 0.1, isLocal: true))
    }

    // Timer-driven activities keep upstream's 1 s rule: group-call speaking is re-added every 2 s against a
    // 3 s receiver timeout, uploads and recordings every 5 s.
    func testTimerDrivenActivitiesKeepTheOneSecondRefresh() {
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .speakingInGroupCall(timestamp: 0), current: .speakingInGroupCall(timestamp: 0), elapsed: 2.0, isLocal: true))
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .uploadingPhoto(progress: 10), current: .uploadingPhoto(progress: 10), elapsed: 5.0, isLocal: true))
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .recordingVoice, current: .recordingVoice, elapsed: 5.0, isLocal: true))
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .choosingSticker, current: .choosingSticker, elapsed: 1.2, isLocal: true))
        XCTAssertFalse(peerInputActivityNeedsReissue(previous: .recordingVoice, current: .recordingVoice, elapsed: 0.5, isLocal: true))
    }

    func testRefreshInterval() {
        XCTAssertEqual(peerInputActivityRefreshInterval(.typingText, isLocal: true), 4.5)
        XCTAssertEqual(peerInputActivityRefreshInterval(.typingText, isLocal: false), 1.0)
        XCTAssertEqual(peerInputActivityRefreshInterval(.speakingInGroupCall(timestamp: Int32.max), isLocal: true), 1.0)
        XCTAssertEqual(peerInputActivityRefreshInterval(.uploadingFile(progress: 0), isLocal: true), 1.0)
    }
}
