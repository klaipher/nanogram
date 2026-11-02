import OSLog
import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// `TDLibResponseRoute.scan` reads `@client_id`, `@extra` and the closed state from the bytes
/// TDLib writes instead of parsing the whole payload. For every TDLib-shaped payload it must
/// agree with the full parse the manager used to do.
final class CoreTDLibRoutingTests: XCTestCase {
    /// The manager's routing before the scan: a full JSONSerialization parse.
    private func reference(_ data: Data) -> TDLibResponseRoute.Route? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var closes = false
        if let state = dict["authorization_state"] as? [String: Any],
           (state["@type"] as? String) == "authorizationStateClosed" {
            closes = true
        }
        return TDLibResponseRoute.Route(
            clientId: dict["@client_id"] as? Int32 ?? 1,
            extra: dict["@extra"] as? String,
            closesClient: closes
        )
    }

    private let uuid = "6F1D3C2A-1111-2222-3333-444455556666"

    private var tdlibShaped: [String] {
        let message = CoreFixtures.messageJSON(id: 5, text: #"a \"@extra\":\"x\" and ,\"@client_id\":9} ünï 😀"#)
        return [
            #"{"@type":"updateUserStatus","user_id":1,"status":{"@type":"userStatusOffline","was_online":1},"@client_id":1}"#,
            #"{"@type":"updateNewMessage","message":\#(message),"@client_id":3}"#,
            #"{"@type":"messages","total_count":1,"messages":[\#(message)],"@extra":"\#(uuid)","@client_id":1}"#,
            #"{"@type":"ok","@extra":"\#(uuid)","@client_id":2}"#,
            #"{"@type":"error","code":400,"message":"Bad \"request\"","@extra":"\#(uuid)","@client_id":1}"#,
            #"{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateClosed"},"@client_id":4}"#,
            #"{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateClosing"},"@client_id":4}"#,
            #"{"@type":"authorizationStateClosed","@extra":"\#(uuid)","@client_id":1}"#,
            #"{"@type":"updateOption","name":"version","value":{"@type":"optionValueString","value":"1.8.64"},"@client_id":2147483647}"#,
            #"{"@type":"updateChatTitle","chat_id":1,"title":"ends with quote \"","@client_id":1}"#,
            #"{"@type":"updateChatTitle","chat_id":1,"title":"\"@extra\":\"spoof","@client_id":1}"#,
            #"{"@type":"text","text":"x","@extra":"","@client_id":1}"#,
        ]
    }

    func testScanAgreesWithAFullParse() throws {
        for json in tdlibShaped {
            let data = Data(json.utf8)
            let expected = try XCTUnwrap(reference(data), json)
            let route = try XCTUnwrap(TDLibResponseRoute.scan(data), "scan gave up on \(json)")
            XCTAssertEqual(route, expected, json)
        }
    }

    /// Anything not shaped like TDLib's output is left to the full parse.
    func testScanDeclinesOtherShapes() {
        for json in [
            "",
            "not json",
            #"{"@client_id":1,"@type":"ok"}"#,
            #"{"@type":"ok","@extra":7,"@client_id":1} "#,
            #"{"@type":"ok","@extra":"a\"b","@client_id":1}"#,
            #"{"@type":"ok","@client_id":99999999999}"#,
        ] {
            XCTAssertNil(TDLibResponseRoute.scan(Data(json.utf8)), json)
        }
    }

    /// The manager's entry point: the scan where it applies, the full parse otherwise.
    func testRouteFallsBackToTheFullParse() {
        for json in [#"{"@client_id":7,"@type":"ok","@extra":"e"}"#, #"{"@type":"ok","@extra":7,"@client_id":1}"#] {
            let data = Data(json.utf8)
            XCTAssertEqual(TDLibResponseRoute.route(data), reference(data), json)
        }
        XCTAssertNil(TDLibResponseRoute.route(Data("[]".utf8)))
    }
}

/// Updates are decoded on TDLib's queue and handed to the main thread in order, several per
/// main-queue turn, but never ahead of a response TDLib sent before them.
final class CoreTDUpdateDeliveryTests: XCTestCase {
    private func json(_ type: String, _ chatId: Int) -> Data {
        switch type {
        case "readInbox":
            return Data(#"{"@type":"updateChatReadInbox","chat_id":\#(chatId),"last_read_inbox_message_id":1,"unread_count":0,"@client_id":1}"#.utf8)
        default:
            return Data(#"{"@type":"updateUserStatus","user_id":\#(chatId),"status":{"@type":"userStatusEmpty"},"@client_id":1}"#.utf8)
        }
    }

    private static func chatId(_ update: Update) -> Int64? {
        if case .updateChatReadInbox(let u) = update { return u.chatId }
        return nil
    }

    func testUpdatesQueuedBeforeMainRunsArriveInOneBatchInOrder() {
        let done = expectation(description: "delivered")
        nonisolated(unsafe) var batches: [[Int64]] = []
        let delivery = TDUpdateDelivery(logger: os.Logger(watchCategory: "test")) { updates in
            XCTAssertTrue(Thread.isMainThread)
            batches.append(updates.compactMap(Self.chatId))
            if batches.flatMap({ $0 }).count == 3 { done.fulfill() }
        }
        let queue = DispatchQueue(label: "test.tdlib.update-handler")
        queue.sync {
            for id in 1...3 { delivery.receive(json("readInbox", id), decoder: JSONDecoder()) }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(batches, [[1, 2, 3]])
    }

    /// A response resumes its awaiting task through the main queue. Updates TDLib sent after it
    /// must not be delivered before it.
    func testAResponseSplitsTheBatch() {
        let done = expectation(description: "delivered")
        nonisolated(unsafe) var log: [String] = []
        let delivery = TDUpdateDelivery(logger: os.Logger(watchCategory: "test")) { updates in
            log.append(updates.compactMap(Self.chatId).map(String.init).joined(separator: ","))
            if log.count == 3 { done.fulfill() }
        }
        let queue = DispatchQueue(label: "test.tdlib.update-handler")
        queue.sync {
            delivery.receive(json("readInbox", 1), decoder: JSONDecoder())
            delivery.responseArrived()
            DispatchQueue.main.async { log.append("response") }
            delivery.receive(json("readInbox", 2), decoder: JSONDecoder())
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(log, ["1", "response", "2"])
    }

    /// Update kinds the models do not cover never reach the main thread.
    func testUnsupportedUpdatesAreDroppedOffMain() {
        let delivered = expectation(description: "nothing delivered")
        delivered.isInverted = true
        let delivery = TDUpdateDelivery(logger: os.Logger(watchCategory: "test")) { _ in delivered.fulfill() }
        DispatchQueue(label: "test.tdlib.update-handler").sync {
            delivery.receive(json("userStatus", 1), decoder: JSONDecoder())
        }
        wait(for: [delivered], timeout: 0.3)
    }
}
