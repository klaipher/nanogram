import XCTest
import Postbox
@testable import TelegramCore

final class UnchangedStateUpdateTests: XCTestCase {
    private let channelId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(77))

    func testAPollWithTheStoredPtsStoresNothing() {
        let current = ChannelState(pts: 100, invalidatedPts: nil, synchronizedUntilMessageId: nil)
        XCTAssertNil(channelStateUpdatedByPoll(current, pts: 100))
        XCTAssertEqual(channelStateUpdatedByPoll(current, pts: 101)?.pts, 101)
        XCTAssertEqual(channelStateUpdatedByPoll(nil, pts: 5)?.pts, 5)
    }

    func testAnUnchangedParticipantsCountStoresNothing() {
        let current = CachedChannelData().withUpdatedParticipantsSummary(CachedChannelParticipantsSummary(memberCount: 10, adminCount: nil, bannedCount: nil, kickedCount: nil))
        XCTAssertNil(cachedChannelDataWithParticipantsCount(current, participantsCount: 10))
        let updated = cachedChannelDataWithParticipantsCount(current, participantsCount: 11) as? CachedChannelData
        XCTAssertEqual(updated?.participantsSummary.memberCount, 11)
        let created = cachedChannelDataWithParticipantsCount(nil, participantsCount: 3) as? CachedChannelData
        XCTAssertEqual(created?.participantsSummary.memberCount, 3)
    }

    func testViewCountsAreStoredOnlyWhenTheyGrow() {
        let attributes: [MessageAttribute] = [ViewCountMessageAttribute(count: 10), ForwardCountMessageAttribute(count: 4)]
        XCTAssertNil(messageAttributesWithIncreasedViewCount(attributes, count: 10))
        XCTAssertNil(messageAttributesWithIncreasedViewCount(attributes, count: 9))
        XCTAssertEqual((messageAttributesWithIncreasedViewCount(attributes, count: 11)?.first as? ViewCountMessageAttribute)?.count, 11)
        XCTAssertNil(messageAttributesWithIncreasedViewCount([], count: 11))
    }

    func testAViewsPollThatChangesNothingReportsNoChange() {
        let commentsId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(78))
        let replier = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(5))
        var attributes: [MessageAttribute] = [
            ViewCountMessageAttribute(count: 100),
            ForwardCountMessageAttribute(count: 2),
            ReplyThreadMessageAttribute(count: 3, latestUsers: [replier], commentsPeerId: commentsId, maxMessageId: 40, maxReadMessageId: 30)
        ]
        let result = MessageViewsPollResult(views: 100, forwards: 2, repliesCount: 3, recentRepliersPeerIds: [replier], commentsChannelId: commentsId, repliesMaxId: 40)
        var readMaxId: Int32? = 30
        XCTAssertFalse(applyMessageViewsPollResult(result, to: &attributes, repliesReadMaxId: &readMaxId).changed)

        var grown = attributes
        var grownResult = result
        grownResult.views = 101
        XCTAssertTrue(applyMessageViewsPollResult(grownResult, to: &grown, repliesReadMaxId: &readMaxId).changed)
        XCTAssertEqual((grown[0] as? ViewCountMessageAttribute)?.count, 101)

        var replied = attributes
        var repliedResult = result
        repliedResult.repliesCount = 4
        XCTAssertTrue(applyMessageViewsPollResult(repliedResult, to: &replied, repliesReadMaxId: &readMaxId).changed)
        XCTAssertEqual((replied[2] as? ReplyThreadMessageAttribute)?.count, 4)

        var withoutReplies: [MessageAttribute] = [ViewCountMessageAttribute(count: 100)]
        var noReadMaxId: Int32?
        XCTAssertTrue(applyMessageViewsPollResult(result, to: &withoutReplies, repliesReadMaxId: &noReadMaxId).changed)
        XCTAssertEqual(withoutReplies.count, 2)
    }
}
