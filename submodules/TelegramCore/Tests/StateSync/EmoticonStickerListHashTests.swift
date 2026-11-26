import Foundation
import XCTest
import SwiftSignalKit
import Postbox
import TelegramApi
@testable import TelegramCore

private let getStickers = "messages.getStickers"

/// The greeting, premium and all-premium sticker lists (`messages.getStickers` with the emoticons "👋⭐️", "⭐️⭐️"
/// and "📂⭐️") are polled at launch and every 3 hours. Upstream asks with hash 0, so the server can never answer
/// `stickersNotModified` and every poll rewrites the whole list (fresh file references change its bytes). The poll
/// now sends back the hash the server returned with the stored list (`messages.stickers.hash`, as the sticker search
/// does), kept with the hash of the ids it was stored with, and asks in full (hash 0) when the list is empty or was
/// changed since. One poll is driven directly, without the 3-hour loop.
final class EmoticonStickerListHashTests: StateSyncTestCase {
    private let collectionId = Namespaces.OrderedItemList.CloudPremiumStickers
    private let emoticon = "⭐️⭐️"

    private func document(id: Int64, fileReference: Data = Data([1])) -> Api.Document {
        return .document(Api.Document.Cons_document(flags: 0, id: id, accessHash: 1, fileReference: Buffer(data: fileReference), date: 0, mimeType: "application/x-tgsticker", size: 100, thumbs: nil, videoThumbs: nil, dcId: 2, attributes: []))
    }

    private func stickers(hash: Int64, ids: [Int64], fileReference: Data = Data([1])) -> Api.messages.Stickers {
        return .stickers(Api.messages.Stickers.Cons_stickers(hash: hash, stickers: ids.map { self.document(id: $0, fileReference: fileReference) }))
    }

    private func payload(hash: Int64) -> Data {
        return Api.functions.messages.getStickers(emoticon: self.emoticon, hash: hash).1.makeData()
    }

    private func poll(file: StaticString = #filePath, line: UInt = #line) {
        let _ = self.fixture.wait(managedEmoticonStickerListPoll(postbox: self.fixture.postbox, network: self.network, collectionId: self.collectionId, emoticon: self.emoticon), file: file, line: line)
    }

    private func assertRequest(_ index: Int, hash: Int64, file: StaticString = #filePath, line: UInt = #line) {
        let requests = self.server.requests
        guard index < requests.count else {
            XCTFail("no request \(index); log: \(requests.map { $0.name })", file: file, line: line)
            return
        }
        XCTAssertEqual(requests[index].name, getStickers, file: file, line: line)
        XCTAssertEqual(requests[index].payload, self.payload(hash: hash), "arguments: \(requests[index].arguments)", file: file, line: line)
    }

    private func storedEntries() -> [OrderedItemListEntry] {
        let collectionId = self.collectionId
        return self.fixture.transaction { transaction in
            transaction.getOrderedListItems(collectionId: collectionId)
        } ?? []
    }

    private func storedIds() -> [Int64] {
        return self.storedEntries().map { RecentMediaItemId($0.id).mediaId.id }
    }

    /// Nothing stored: the first poll asks in full, stores the answer and keeps its hash; the next poll sends it.
    func testFirstPollAsksInFullAndTheNextSendsTheServerHash() {
        self.server.on(getStickers, .result(self.stickers(hash: 42, ids: [1, 2, 3])))
        self.server.on(getStickers, .result(Api.messages.Stickers.stickersNotModified))

        self.poll()
        XCTAssertEqual(self.storedIds(), [1, 2, 3])
        self.poll()

        XCTAssertEqual(self.server.requestNames, [getStickers, getStickers])
        self.assertRequest(0, hash: 0)
        self.assertRequest(1, hash: 42)
    }

    /// `stickersNotModified` leaves the stored list exactly as it was (same ids, same bytes, so the old file
    /// references), and the poll after it sends the same hash again.
    func testNotModifiedLeavesTheListAndTheHashAsTheyWere() {
        self.server.on(getStickers, .result(self.stickers(hash: 42, ids: [1, 2], fileReference: Data([7]))))
        self.server.on(getStickers, .result(Api.messages.Stickers.stickersNotModified))
        self.server.on(getStickers, .result(Api.messages.Stickers.stickersNotModified))

        self.poll()
        let before = self.storedEntries().map { $0.contents.data }
        self.poll()
        self.poll()

        XCTAssertEqual(self.storedIds(), [1, 2])
        XCTAssertEqual(self.storedEntries().map { $0.contents.data }, before)
        self.assertRequest(1, hash: 42)
        self.assertRequest(2, hash: 42)
    }

    /// A full answer replaces the list and its hash together: the poll after it sends the new hash.
    func testFullAnswerReplacesTheListAndTheHashTogether() {
        self.server.on(getStickers, .result(self.stickers(hash: 42, ids: [1, 2])))
        self.server.on(getStickers, .result(self.stickers(hash: 43, ids: [2, 4])))
        self.server.on(getStickers, .result(Api.messages.Stickers.stickersNotModified))

        self.poll()
        self.poll()
        XCTAssertEqual(self.storedIds(), [2, 4])
        self.poll()

        self.assertRequest(1, hash: 42)
        self.assertRequest(2, hash: 43)
    }

    /// A list changed since it was stored with the hash (not by this poll) is asked for in full, so a stale hash
    /// can never keep a list the server no longer matches.
    func testListChangedElsewhereIsAskedForInFull() {
        self.server.on(getStickers, .result(self.stickers(hash: 42, ids: [1, 2])))
        self.server.on(getStickers, .result(Api.messages.Stickers.stickersNotModified))

        self.poll()
        let collectionId = self.collectionId
        let kept = self.storedEntries().prefix(1)
        self.fixture.transaction { transaction in
            transaction.replaceOrderedItemListItems(collectionId: collectionId, items: Array(kept))
        }
        self.poll()

        self.assertRequest(1, hash: 0)
    }

    /// A list emptied since it was stored is asked for in full: the server would otherwise answer "not modified"
    /// and leave it empty for good.
    func testEmptiedListIsAskedForInFull() {
        self.server.on(getStickers, .result(self.stickers(hash: 42, ids: [1, 2])))
        self.server.on(getStickers, .result(self.stickers(hash: 42, ids: [1, 2])))

        self.poll()
        let collectionId = self.collectionId
        self.fixture.transaction { transaction in
            transaction.replaceOrderedItemListItems(collectionId: collectionId, items: [])
        }
        self.poll()

        self.assertRequest(1, hash: 0)
        XCTAssertEqual(self.storedIds(), [1, 2])
    }

    /// An answer whose hash is 0, or an empty answer, keeps no hash: the next poll asks in full.
    func testZeroHashOrEmptyAnswerKeepsNoHash() {
        self.server.on(getStickers, .result(self.stickers(hash: 0, ids: [1, 2])))
        self.server.on(getStickers, .result(self.stickers(hash: 42, ids: [])))
        self.server.on(getStickers, .result(Api.messages.Stickers.stickersNotModified))

        self.poll()
        self.poll()
        XCTAssertEqual(self.storedIds(), [])
        self.poll()

        self.assertRequest(1, hash: 0)
        self.assertRequest(2, hash: 0)
    }

    /// The hash is kept per list: another list's stored hash is never sent for this one.
    func testHashIsKeptPerList() {
        let otherCollectionId = Namespaces.OrderedItemList.CloudAllPremiumStickers
        let otherEmoticon = "📂⭐️"
        self.server.on(getStickers, .result(self.stickers(hash: 99, ids: [1, 2])))
        self.server.on(getStickers, .result(self.stickers(hash: 42, ids: [1, 2])))

        let _ = self.fixture.wait(managedEmoticonStickerListPoll(postbox: self.fixture.postbox, network: self.network, collectionId: otherCollectionId, emoticon: otherEmoticon))
        self.poll()

        XCTAssertEqual(self.server.requests.count, 2)
        XCTAssertEqual(self.server.requests.first?.payload, Api.functions.messages.getStickers(emoticon: otherEmoticon, hash: 0).1.makeData())
        self.assertRequest(1, hash: 0)
    }
}
