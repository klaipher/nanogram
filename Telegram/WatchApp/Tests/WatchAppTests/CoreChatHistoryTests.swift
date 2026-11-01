import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// `getChatHistory` answered with an error must not read as "no more messages".
final class CoreChatHistoryResponseTests: XCTestCase {
    func testErrorResponseThrowsTheTDLibError() {
        let json = #"{"@type":"error","code":400,"message":"Chat not found","@extra":"x"}"#
        XCTAssertThrowsError(try TDLibChatHistoryLoader.decodeMessagesLeniently(
            Data(json.utf8), chatId: 1, decoder: CoreFixtures.tdlibDecoder()
        )) { error in
            XCTAssertEqual(error as? TDError, TDError(code: 400, message: "Chat not found"))
        }
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try TDLibChatHistoryLoader.decodeMessagesLeniently(
            Data("[]".utf8), chatId: 1, decoder: CoreFixtures.tdlibDecoder()
        ))
    }

    func testMessagesDecodeAndUndecodableOnesAreSkipped() throws {
        let json = """
        {"@type":"messages","total_count":2,"messages":[\(CoreFixtures.messageJSON(id: 5)),{"@type":"message","id":6}]}
        """
        let messages = try TDLibChatHistoryLoader.decodeMessagesLeniently(
            Data(json.utf8), chatId: 1, decoder: CoreFixtures.tdlibDecoder()
        )
        XCTAssertEqual(messages.map(\.id), [5])
    }

    func testEmptyHistoryIsNotAnError() throws {
        let json = #"{"@type":"messages","total_count":0,"messages":[]}"#
        let messages = try TDLibChatHistoryLoader.decodeMessagesLeniently(
            Data(json.utf8), chatId: 1, decoder: CoreFixtures.tdlibDecoder()
        )
        XCTAssertTrue(messages.isEmpty)
    }
}

@MainActor
final class CoreChatHistoryStoreTests: XCTestCase {
    /// A failed page used to look like the end of the chat: `hasOlder` went false for good.
    func testFailedOlderPageKeepsOlderHistoryReachable() async throws {
        let loader = CoreFakeHistoryLoader()
        await loader.setHistoryResult(.success([try CoreFixtures.message(id: 20)]))
        let store = CoreFixtures.historyStore(loader: loader)
        await store.start()
        XCTAssertEqual(store.loadState, .loaded)

        await loader.setHistoryResult(.failure(TDError(code: 500, message: "Request timeout")))
        await store.loadOlder()
        XCTAssertTrue(store.window.hasOlder)
    }

    func testFailedFirstPageShowsRetry() async {
        let loader = CoreFakeHistoryLoader()
        await loader.setHistoryResult(.failure(TDError(code: 400, message: "Chat not found")))
        let store = CoreFixtures.historyStore(loader: loader)
        await store.start()
        guard case .failed = store.loadState else {
            return XCTFail("expected .failed, got \(store.loadState)")
        }
    }
}
