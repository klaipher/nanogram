import Foundation
import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

// A clock the test moves by hand. The manager reads it on its own queue, so moves go through
// `PeerInputActivityManager.transaction`, which runs in order with the adds on that queue.
private final class ManualClock {
    private let lock = NSLock()
    private var value: Double = 1_000_000.0

    func now() -> Double {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }

    func advance(_ seconds: Double) {
        self.lock.lock()
        self.value += seconds
        self.lock.unlock()
    }
}

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
    // Elapsed 1.2 s, below the 4.5 s typing interval, so each of these pins the 1 s rule.
    func testTimerDrivenActivitiesKeepTheOneSecondRefresh() {
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .speakingInGroupCall(timestamp: 0), current: .speakingInGroupCall(timestamp: 0), elapsed: 1.2, isLocal: true))
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .uploadingPhoto(progress: 10), current: .uploadingPhoto(progress: 10), elapsed: 1.2, isLocal: true))
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .recordingVoice, current: .recordingVoice, elapsed: 1.2, isLocal: true))
        XCTAssertTrue(peerInputActivityNeedsReissue(previous: .choosingSticker, current: .choosingSticker, elapsed: 1.2, isLocal: true))
        XCTAssertFalse(peerInputActivityNeedsReissue(previous: .recordingVoice, current: .recordingVoice, elapsed: 0.5, isLocal: true))
    }

    func testRefreshInterval() {
        XCTAssertEqual(peerInputActivityRefreshInterval(.typingText, isLocal: true), 4.5)
        XCTAssertEqual(peerInputActivityRefreshInterval(.typingText, isLocal: false), 1.0)
        XCTAssertEqual(peerInputActivityRefreshInterval(.speakingInGroupCall(timestamp: Int32.max), isLocal: true), 1.0)
        XCTAssertEqual(peerInputActivityRefreshInterval(.uploadingFile(progress: 0), isLocal: true), 1.0)
    }

    // The manager wiring: isLocal reaches the context through the manager, so a repeated .typingText add
    // 1.2 s later keeps its update id (nothing is sent) in our own manager and gets a new one in the incoming one.
    func testLocalManagerKeepsTheTypingUpdateIdForFourAndAHalfSeconds() {
        let clock = ManualClock()
        let manager = PeerInputActivityManager(isLocal: true, now: { clock.now() })
        let ids = self.typingUpdateIds(manager, clock: clock, steps: [1.2, 3.2, 0.2])
        XCTAssertEqual(ids.count, 4)
        guard ids.count == 4, let initial = ids[0] else {
            return
        }
        // +1.2 s and +4.4 s: unchanged. +4.6 s: re-issued.
        XCTAssertEqual(ids[1], initial)
        XCTAssertEqual(ids[2], initial)
        XCTAssertNotNil(ids[3])
        XCTAssertNotEqual(ids[3], initial)
    }

    func testIncomingManagerReissuesTypingAfterOneSecond() {
        let clock = ManualClock()
        let manager = PeerInputActivityManager(isLocal: false, now: { clock.now() })
        let ids = self.typingUpdateIds(manager, clock: clock, steps: [1.2])
        XCTAssertEqual(ids.count, 2)
        guard ids.count == 2, let initial = ids[0] else {
            return
        }
        XCTAssertNotNil(ids[1])
        XCTAssertNotEqual(ids[1], initial)
    }

    // Adds .typingText, then for each step moves the clock and adds it again; returns the typing update id
    // after the first add and after each step.
    private func typingUpdateIds(_ manager: PeerInputActivityManager, clock: ManualClock, steps: [Double]) -> [Int32?] {
        let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1))
        let space = PeerActivitySpace(peerId: peerId, category: .global)
        var result: [Int32?] = []
        manager.addActivity(chatPeerId: space, peerId: peerId, activity: .typingText)
        result.append(self.currentTypingUpdateId(manager, space: space, peerId: peerId))
        for step in steps {
            manager.transaction { _ in
                clock.advance(step)
            }
            manager.addActivity(chatPeerId: space, peerId: peerId, activity: .typingText)
            result.append(self.currentTypingUpdateId(manager, space: space, peerId: peerId))
        }
        return result
    }

    private func currentTypingUpdateId(_ manager: PeerInputActivityManager, space: PeerActivitySpace, peerId: PeerId) -> Int32? {
        let done = self.expectation(description: "activities")
        var updateId: Int32?
        let disposable = (manager.allActivities() |> take(1)).start(next: { activities in
            updateId = activities[space]?.first(where: { $0.0 == peerId && $0.1.activity == .typingText })?.1.updateId
            done.fulfill()
        })
        self.wait(for: [done], timeout: 3.0)
        disposable.dispose()
        return updateId
    }
}
