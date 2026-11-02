import OSLog
import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// TDLib delivers updates on the client's own serial queue, never on main.
final class CoreTDClientUpdateHandlerTests: XCTestCase {
    func testUpdateDecoderRunsOnTDLibQueueAndDeliversOnMain() {
        let delivered = expectation(description: "update delivered")
        let delivery = TDUpdateDelivery(logger: os.Logger(watchCategory: "test")) { updates in
            XCTAssertTrue(Thread.isMainThread)
            guard updates.count == 1, case .updateAuthorizationState(let upd) = updates[0],
                  case .authorizationStateWaitTdlibParameters = upd.authorizationState else {
                return XCTFail("unexpected updates \(updates)")
            }
            delivered.fulfill()
        }
        let json = #"{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitTdlibParameters"},"@client_id":1}"#
        DispatchQueue(label: "test.tdlib.update-handler").async {
            delivery.receive(Data(json.utf8), decoder: CoreFixtures.tdlibDecoder())
        }
        wait(for: [delivered], timeout: 2)
    }

    func testUndecodableUpdateIsDropped() {
        let delivered = expectation(description: "nothing delivered")
        delivered.isInverted = true
        let delivery = TDUpdateDelivery(logger: os.Logger(watchCategory: "test")) { _ in delivered.fulfill() }
        DispatchQueue.global().async {
            delivery.receive(Data("not json".utf8), decoder: CoreFixtures.tdlibDecoder())
        }
        wait(for: [delivered], timeout: 0.3)
    }
}

final class CoreTDLibReadyOptionsTests: XCTestCase {
    /// Without the storage optimizer TDLib never deletes a downloaded file.
    func testStorageOptimizerIsTurnedOn() throws {
        let encoder = JSONEncoder()
        let queries = try TDLibReadyOptions.all.map { option -> [String: Any] in
            let data = try encoder.encode(DTO(option, encoder: encoder))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let optimizer = try XCTUnwrap(queries.first { $0["name"] as? String == "use_storage_optimizer" })
        XCTAssertEqual(optimizer["@type"] as? String, "setOption")
        let value = try XCTUnwrap(optimizer["value"] as? [String: Any])
        XCTAssertEqual(value["@type"] as? String, "optionValueBoolean")
        XCTAssertEqual(value["value"] as? Bool, true)
    }
}

@MainActor
final class CoreTDClientSceneTests: XCTestCase {
    private final class Delegate: TDClientLifecycleDelegate {
        func tdClient(_ client: TDClient, didFetchMe me: User) {}
        func tdClient(_ client: TDClient, didDestroyItselfWithReason reason: TDClientDestroyReason) {}
    }

    /// Wrist down with a chat open: an incoming message scrolls into view, but nobody reads it.
    func testOpenChatHoldsReadsWhileSceneIsInactive() async {
        let delegate = Delegate()
        let client = TDClient(account: CoreAccountFixtures.account(), makeClient: { _ in
            fatalError("TDLib is not used here")
        }, delegate: delegate)
        let loader = CoreFakeHistoryLoader()
        let store = CoreFixtures.historyStore(loader: loader)
        client.setActiveHistory(store)

        client.setSceneActive(false)
        store.markVisible(messageId: 10)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let viewedWhileInactive = await loader.viewed
        XCTAssertEqual(viewedWhileInactive, [])

        client.setSceneActive(true)
        let drained = await coreWait { await loader.viewed == [[10]] }
        let viewed = await loader.viewed
        XCTAssertTrue(drained, "\(viewed)")
    }

    func testChatOpenedWhileInactiveStartsHoldingReads() async {
        let delegate = Delegate()
        let client = TDClient(account: CoreAccountFixtures.account(), makeClient: { _ in
            fatalError("TDLib is not used here")
        }, delegate: delegate)
        client.setSceneActive(false)
        let loader = CoreFakeHistoryLoader()
        let store = CoreFixtures.historyStore(loader: loader)
        client.setActiveHistory(store)

        store.markVisible(messageId: 7)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let viewed = await loader.viewed
        XCTAssertEqual(viewed, [])
    }

    func testActiveSceneMarksReadAfterTheDebounce() async {
        let loader = CoreFakeHistoryLoader()
        let store = CoreFixtures.historyStore(loader: loader)
        store.markVisible(messageId: 3)
        store.markVisible(messageId: 4)
        let drained = await coreWait { await loader.viewed == [[3, 4]] }
        let viewed = await loader.viewed
        XCTAssertTrue(drained, "\(viewed)")
    }
}
