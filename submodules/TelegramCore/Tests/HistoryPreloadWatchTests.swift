import XCTest
import Postbox
@testable import TelegramCore

final class HistoryPreloadWatchTests: XCTestCase {
    private let peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(1))

    private func index(_ id: Int32) -> ChatListIndex {
        return ChatListIndex(pinningIndex: nil, messageIndex: MessageIndex(id: MessageId(peerId: self.peerId, namespace: Namespaces.Message.Cloud, id: id), timestamp: id))
    }

    func testAFilledChatStopsReplayingTransactions() {
        XCTAssertFalse(historyPreloadKeepsWatching(hasHole: false))
        XCTAssertTrue(historyPreloadKeepsWatching(hasHole: true))
    }

    func testANewMessageInAFilledChatStartsWatchingAgain() {
        XCTAssertTrue(historyPreloadNeedsWatching(isWatching: false, previousIndex: self.index(10), index: self.index(11)))
        XCTAssertFalse(historyPreloadNeedsWatching(isWatching: false, previousIndex: self.index(10), index: self.index(10)))
        XCTAssertFalse(historyPreloadNeedsWatching(isWatching: true, previousIndex: self.index(10), index: self.index(11)))
    }
}
