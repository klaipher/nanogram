import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

final class PostboxUnchangedPeerWriteTests: XCTestCase {
    private var fixture: PostboxFixture!
    private let namespace = PostboxFixture.messageNamespace

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "PostboxUnchangedPeerWriteTests")
    }

    override func tearDown() {
        self.fixture?.close()
        self.fixture = nil
        super.tearDown()
    }

    private func peerId(_ id: Int64) -> PeerId {
        return MessageHistoryTableFixture.peerId(id)
    }

    func testStoringAnIdenticalPeerIsAnEmptyTransaction() {
        let peerId = self.peerId(1)
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Channel")], update: { _, updated in updated })
        }
        let before = self.fixture.writeTransactionCount()
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Channel")], update: { _, updated in updated })
        }
        XCTAssertEqual(self.fixture.writeTransactionCount(), before, "an identical peer must not be written")

        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Renamed")], update: { _, updated in updated })
        }
        XCTAssertEqual(self.fixture.writeTransactionCount(), before + 1)
        let stored = self.fixture.transaction { transaction in
            return transaction.getPeer(peerId) as? FixturePeer
        }
        XCTAssertEqual(stored??.title, "Renamed")
    }

    func testAChangeThatIsEqualIgnoresIsStillStored() {
        let peerId = self.peerId(2)
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Group")], update: { _, updated in updated })
        }
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Group", associatedPeerId: self.peerId(3))], update: { _, updated in updated })
        }
        let stored = self.fixture.transaction { transaction in
            return transaction.getPeer(peerId) as? FixturePeer
        }
        XCTAssertEqual(stored??.associatedPeerId, self.peerId(3))
    }

    func testReMergingAnUnchangedChannelPeerDoesNotUpdateItsHistoryView() {
        let peerId = self.peerId(10)
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Channel")], update: { _, updated in updated })
            transaction.removeHole(peerId: peerId, threadId: nil, namespace: self.namespace, space: .everywhere, range: 1 ... (Int32.max - 1))
            var messages: [StoreMessage] = []
            for i in 1 ... 100 {
                messages.append(MessageHistoryTableFixture.storeMessage(id: MessageId(peerId: peerId, namespace: self.namespace, id: Int32(i)), timestamp: Int32(1000 + i), text: "\(i)", flags: [.Incoming]))
            }
            let _ = transaction.addMessages(messages, location: .Random)
        }
        let history = self.fixture.observe(self.fixture.postbox.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: nil), anchor: .upperBound, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: [], count: 100, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tag: nil, appendMessagesFromTheSameGroup: false, namespaces: .all, orderStatistics: [], additionalData: []) |> map { $0.0 })
        history.waitForValues(count: 1)
        self.fixture.transaction { _ in }
        let initial = history.values.count
        XCTAssertEqual(history.values.last?.entries.count, 100)

        for _ in 0 ..< 5 {
            self.fixture.transaction { transaction in
                transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Channel")], update: { _, updated in updated })
            }
        }
        self.fixture.transaction { _ in }
        XCTAssertEqual(history.values.count - initial, 0, "unchanged peer re-merged: no history view update")

        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: peerId, title: "Renamed")], update: { _, updated in updated })
        }
        let values = history.waitForValues(count: initial + 1)
        XCTAssertEqual((values.last?.entries.last?.message.peers[peerId] as? FixturePeer)?.title, "Renamed")
    }

    func testIdenticalCachedDataIsNeitherStoredNorReported() {
        let peerId = self.peerId(20)
        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in FixtureCachedPeerData(peerIds: [self.peerId(21)]) })
        }
        let recorder = self.fixture.observe(.cachedPeerData(peerId: peerId), as: CachedPeerDataView.self)
        recorder.waitForValues(count: 1)

        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in FixtureCachedPeerData(peerIds: [self.peerId(21)]) })
        }
        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, current in current })
        }
        self.fixture.transaction { _ in }
        XCTAssertEqual(recorder.values.count, 1, "no change, no update")

        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in FixtureCachedPeerData(peerIds: [self.peerId(22)]) })
        }
        let values = recorder.waitForValues(count: 2)
        XCTAssertEqual((values.last?.cachedPeerData as? FixtureCachedPeerData)?.peerIds, [self.peerId(22)])
        let stored = self.fixture.transaction { transaction in
            return transaction.getPeerCachedData(peerId: peerId) as? FixtureCachedPeerData
        }
        XCTAssertEqual(stored??.peerIds, [self.peerId(22)])
    }
}
