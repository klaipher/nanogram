import XCTest
import Postbox
@testable import TelegramCore

/// Validation stores a message again when the server's copy has the same edit date. When
/// that copy is what is already stored, the message is left alone (`.skip`) instead of being
/// rewritten with a new stable version, which re-renders it in every view.
final class HistoryValidationRestoreTests: XCTestCase {
    private let messageId = MessageId(peerId: PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(77)), namespace: Namespaces.Message.Cloud, id: 10)

    private func message(attributes: [MessageAttribute], tags: MessageTags = []) -> Message {
        return Message(stableId: 1, stableVersion: 3, id: self.messageId, globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 100, flags: [.Incoming], tags: tags, globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: nil, text: "text", attributes: attributes, media: [], peers: SimpleDictionary(), associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    }

    private func pts(_ message: StoreMessage?) -> [Int32] {
        return (message?.attributes ?? []).compactMap { ($0 as? ChannelMessageStateVersionAttribute)?.pts }
    }

    func testNoChannelVersionLeavesTheMessageAlone() {
        XCTAssertNil(historyValidationRestoredMessage(self.message(attributes: []), id: self.messageId, channelPts: nil))
        XCTAssertNil(historyValidationRestoredMessage(self.message(attributes: [ChannelMessageStateVersionAttribute(pts: 5)]), id: self.messageId, channelPts: nil))
    }

    func testTheSameChannelVersionLeavesTheMessageAlone() {
        let current = self.message(attributes: [EditedMessageAttribute(date: 50, isHidden: false), ChannelMessageStateVersionAttribute(pts: 7)])
        XCTAssertNil(historyValidationRestoredMessage(current, id: self.messageId, channelPts: 7))
    }

    func testANewChannelVersionIsStored() {
        let current = self.message(attributes: [ChannelMessageStateVersionAttribute(pts: 7)])
        let restored = historyValidationRestoredMessage(current, id: self.messageId, channelPts: 8)
        XCTAssertEqual(self.pts(restored), [8])
        XCTAssertEqual(restored?.text, "text")
    }

    func testAMissingChannelVersionIsStored() {
        let restored = historyValidationRestoredMessage(self.message(attributes: []), id: self.messageId, channelPts: Int32.max)
        XCTAssertEqual(self.pts(restored), [Int32.max])
    }

    /// The version is stored as the last attribute, once. Any other layout is rewritten so
    /// the stored bytes come out as before this change.
    func testAVersionThatIsNotLastOrIsRepeatedIsStoredAgain() {
        let notLast = self.message(attributes: [ChannelMessageStateVersionAttribute(pts: 7), EditedMessageAttribute(date: 50, isHidden: false)])
        XCTAssertEqual(self.pts(historyValidationRestoredMessage(notLast, id: self.messageId, channelPts: 7)), [7])
        let repeated = self.message(attributes: [ChannelMessageStateVersionAttribute(pts: 7), ChannelMessageStateVersionAttribute(pts: 7)])
        XCTAssertEqual(self.pts(historyValidationRestoredMessage(repeated, id: self.messageId, channelPts: 7)), [7])
    }

    /// Storing such a message is what marks its reactions or poll votes seen while it is on
    /// screen, so it is always stored.
    func testUnseenReactionsAndPollVotesAreAlwaysStored() {
        XCTAssertNotNil(historyValidationRestoredMessage(self.message(attributes: [], tags: [.unseenReaction]), id: self.messageId, channelPts: nil))
        XCTAssertNotNil(historyValidationRestoredMessage(self.message(attributes: [ChannelMessageStateVersionAttribute(pts: 0)], tags: [.unseenPollVote]), id: self.messageId, channelPts: 0))
    }

    func testTheExtremeVersionsCompareExactly() {
        for value in [Int32.min, 0, Int32.max] {
            XCTAssertNil(historyValidationRestoredMessage(self.message(attributes: [ChannelMessageStateVersionAttribute(pts: value)]), id: self.messageId, channelPts: value))
        }
    }
}
