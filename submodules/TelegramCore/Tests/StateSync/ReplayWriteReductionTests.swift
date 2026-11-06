import Foundation
import XCTest
import Postbox
@testable import TelegramCore

/// Nanogram's write reductions inside upstream 13.2's replay (`UnchangedStateUpdates.swift`, called from
/// `StateReplay+StateAdvance.swift` and `StateReplay+Messages.swift`): a view count that does not raise the stored one,
/// and a channel pts that stays where it is, write nothing. Driven through `FinalStateReplayer.applyReplay` over the
/// harness's Postbox, without a state manager. The equal-participants-count skip is `UnchangedStateUpdateTests`.
final class ReplayWriteReductionTests: StateSyncTestCase {
    private let channelId: Int64 = 300

    private var channel: PeerId {
        return StateSyncFixture.channelPeerId(self.channelId)
    }

    private func finalState(_ operations: [AccountStateMutationOperation]) -> AccountFinalState {
        // The verified replay is refused when a channel it moves has a stored state the snapshot lacks, so the snapshot carries the stored pts.
        var snapshotChannelStates: [PeerId: AccountStateChannelState] = [:]
        if let stored = self.channelState() {
            snapshotChannelStates[self.channel] = AccountStateChannelState(pts: stored.pts)
        }
        let initialState = AccountInitialState(state: self.state(pts: 100), peerIds: Set(), peerIdsRequiringLocalChatState: Set(), channelStates: snapshotChannelStates, peerChatInfos: [:], locallyGeneratedMessageTimestamps: [:], channelsToPollExplicitely: Set())
        var state = AccountMutableState(initialState: initialState, initialPeers: [:], initialReferencedReplyMessageIds: ReferencedReplyMessageIds(), initialReferencedGeneralMessageIds: Set(), initialStoredMessages: Set(), initialStoredStories: [:], initialReadInboxMaxIds: [:], storedMessagesByPeerIdAndTimestamp: [:], initialSentScheduledMessageIds: Set())
        state.operations.append(contentsOf: operations)
        return AccountFinalState(state: state, shouldPoll: false, incomplete: false, discard: false)
    }

    private func replay(_ operations: [AccountStateMutationOperation]) -> Bool {
        let finalState = self.finalState(operations)
        let replayer = FinalStateReplayer(accountManager: self.fixture.accountManager, postbox: self.fixture.postbox, accountPeerId: StateSyncFixture.accountPeerId, encryptionProvider: UnusedEncryptionProvider(), auxiliaryMethods: StateSyncFixture.makeAuxiliaryMethods(), messagesRemovedContext: MessagesRemovedContext())
        return self.fixture.transaction { transaction -> Bool in
            return replayer.applyReplay(finalState, policy: .verified, removePossiblyDeliveredMessagesUniqueIds: [:], transaction: transaction) != nil
        } ?? false
    }

    private func storeChannelPost(_ id: Int32, views: Int) {
        let message = StoreMessage(id: self.messageId(self.channel, id), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: 1, timestamp: self.baseDate + id, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: self.channel, text: "post", attributes: [ViewCountMessageAttribute(count: views)], media: [])
        self.fixture.transaction { transaction -> Void in
            let _ = transaction.addMessages([message], location: .UpperHistoryBlock)
        }
    }

    private func viewCount(_ id: Int32) -> Int? {
        return self.fixture.message(self.messageId(self.channel, id))?.attributes.compactMap { $0 as? ViewCountMessageAttribute }.first?.count
    }

    private func seedChannel(pts: Int32) {
        self.fixture.seedAccount(state: self.state(pts: 100))
        self.fixture.seedChannel(StateSyncFixture.makeChannel(id: self.channel, accessHash: 1, title: "C\(self.channelId)"), state: ChannelState(pts: pts, invalidatedPts: 7, synchronizedUntilMessageId: nil))
    }

    private func channelState() -> ChannelState? {
        return self.fixture.transaction { transaction -> ChannelState? in
            return transaction.getPeerChatState(self.channel) as? ChannelState
        } ?? nil
    }

    /// A count that is not above the stored one leaves the stored message untouched (same `stableVersion`); a higher one is stored.
    func testAViewCountThatDoesNotRaiseTheStoredOneWritesNothing() {
        self.seedChannel(pts: 50)
        self.storeChannelPost(10, views: 100)
        let id = self.messageId(self.channel, 10)
        let version = self.fixture.message(id)?.stableVersion

        XCTAssertTrue(self.replay([.UpdateMessageImpressionCount(id, 100)]))
        XCTAssertTrue(self.replay([.UpdateMessageImpressionCount(id, 90)]))
        XCTAssertEqual(self.viewCount(10), 100)
        XCTAssertEqual(self.fixture.message(id)?.stableVersion, version, "an unchanged count rewrote the message")

        XCTAssertTrue(self.replay([.UpdateMessageImpressionCount(id, 120)]))
        XCTAssertEqual(self.viewCount(10), 120)
        XCTAssertNotEqual(self.fixture.message(id)?.stableVersion, version)
    }

    /// A channel pts equal to the stored one keeps the stored state as it is (invalidated pts included); a higher one advances only the pts.
    func testAChannelPtsThatStaysWhereItIsKeepsTheStoredState() {
        self.seedChannel(pts: 50)

        XCTAssertTrue(self.replay([.UpdateChannelState(self.channel, 50)]))
        XCTAssertEqual(self.channelState()?.pts, 50)
        XCTAssertEqual(self.channelState()?.invalidatedPts, 7)

        XCTAssertTrue(self.replay([.UpdateChannelState(self.channel, 51)]))
        XCTAssertEqual(self.channelState()?.pts, 51)
        XCTAssertEqual(self.channelState()?.invalidatedPts, 7)
    }
}
