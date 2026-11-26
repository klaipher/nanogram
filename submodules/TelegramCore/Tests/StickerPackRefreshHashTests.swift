import Foundation
import XCTest
@testable import TelegramApi
@testable import TelegramCore

/// A forced refresh of a cached sticker pack (the 2 h animated-emoji polls, the status and topic
/// icon sets at launch) sent `messages.getStickerSet` with hash 0, so the server always answered
/// with the whole set and every answer rewrote the cache, about 1 MB of WAL per launch for packs
/// whose hash had not changed. A refresh of a consistent cached pack now sends the cached hash and
/// the server answers `stickerSetNotModified`. File-reference revalidation still asks with hash 0,
/// because it needs the fresh references a full answer carries.
final class StickerPackRefreshHashTests: XCTestCase {
    func testConsistentCachedPackSendsItsHash() {
        XCTAssertEqual(stickerPackRefreshKnownHash(cachedHash: 123456, cacheIsStale: false), 123456)
        XCTAssertEqual(stickerPackRefreshKnownHash(cachedHash: -7, cacheIsStale: false), -7)
    }

    func testMissingCachedPackAsksForTheWholeSet() {
        XCTAssertEqual(stickerPackRefreshKnownHash(cachedHash: nil, cacheIsStale: true), 0)
        XCTAssertEqual(stickerPackRefreshKnownHash(cachedHash: nil, cacheIsStale: false), 0)
    }

    func testStaleCachedPackAsksForTheWholeSet() {
        // A cached entry whose stored hash differs from its info's hash is reloaded in full.
        XCTAssertEqual(stickerPackRefreshKnownHash(cachedHash: 123456, cacheIsStale: true), 0)
    }

    func testRequestCarriesTheKnownHash() {
        let request = stickerSetRequest(reference: .animatedEmoji, knownHash: 123456)
        let expected = Api.functions.messages.getStickerSet(stickerset: .inputStickerSetAnimatedEmoji, hash: 123456)
        XCTAssertEqual(request.0.name, "messages.getStickerSet")
        XCTAssertEqual(request.1.makeData(), expected.1.makeData())
    }

    func testRequestWithoutAKnownHashAsksForTheWholeSet() {
        // What file-reference revalidation sends (it never passes a known hash).
        let request = stickerSetRequest(reference: .id(id: 42, accessHash: 99), knownHash: 0)
        let expected = Api.functions.messages.getStickerSet(stickerset: .inputStickerSetID(.init(id: 42, accessHash: 99)), hash: 0)
        XCTAssertEqual(request.1.makeData(), expected.1.makeData())
        XCTAssertNotEqual(request.1.makeData(), stickerSetRequest(reference: .id(id: 42, accessHash: 99), knownHash: 1).1.makeData())
    }
}
