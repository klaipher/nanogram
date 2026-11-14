import AppIntents
import XCTest
import NanogramGlance
import NanogramAppIntents

private actor Recorder {
    var opened: [String] = []
    var sent: [String] = []

    func open(_ key: String) {
        self.opened.append(key)
    }

    func send(_ text: String) {
        self.sent.append(text)
    }
}

private func snapshot(enabled: Bool = true, peers: [GlancePeerRef]) -> GlanceSnapshot {
    return GlanceSnapshot(enabled: enabled, displayNameOnLockscreen: true, peers: peers, savedMessages: GlancePeerRef(accountId: 1, peerId: 1, title: "Saved Messages", isSavedMessages: true))
}

private func handler(recorder: Recorder, sendResult: GlanceSendResult) -> GlanceIntentHandler {
    return GlanceIntentHandler(
        openChat: { accountId, peerId in
            await recorder.open("\(accountId):\(peerId)")
            return true
        },
        sendToSavedMessages: { _, text in
            await recorder.send(text)
            return sendResult
        },
        stopLiveLocation: { _, _ in },
        endCall: { }
    )
}

@available(iOS 16.0, macOS 13.0, *)
final class PeerEntityQueryTests: XCTestCase {
    override func tearDown() {
        NanogramIntentEnvironment.snapshotReader = { nil }
        super.tearDown()
    }

    func testChatOutsideTheTopChatsStillResolves() async throws {
        NanogramIntentEnvironment.snapshotReader = { snapshot(peers: [GlancePeerRef(accountId: 1, peerId: 10, title: "Anna")]) }
        let result = try await PeerEntityQuery().entities(for: ["1:10", "1:77"])
        XCTAssertEqual(result.map { $0.title }, ["Anna", PeerEntityQuery.genericTitle])
        XCTAssertEqual(result.map { $0.id }, ["1:10", "1:77"])
    }

    func testLockedSnapshotResolvesWithGenericTitlesAndSuggestsNothing() async throws {
        NanogramIntentEnvironment.snapshotReader = { snapshot(peers: []) }
        let query = PeerEntityQuery()
        let resolved = try await query.entities(for: ["1:10"])
        XCTAssertEqual(resolved.map { $0.id }, ["1:10"])
        let suggested = try await query.suggestedEntities()
        XCTAssertTrue(suggested.isEmpty)
        let matching = try await query.entities(matching: "a")
        XCTAssertTrue(matching.isEmpty)
    }

    func testListedChatsAreSuggestedAndSearchable() async throws {
        NanogramIntentEnvironment.snapshotReader = { snapshot(peers: [GlancePeerRef(accountId: 1, peerId: 10, title: "Anna"), GlancePeerRef(accountId: 1, peerId: 11, title: "Bob")]) }
        let query = PeerEntityQuery()
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.count, 2)
        let matching = try await query.entities(matching: "AN")
        XCTAssertEqual(matching.map { $0.title }, ["Anna"])
    }

    func testDisabledSnapshotSuggestsNothing() async throws {
        NanogramIntentEnvironment.snapshotReader = { snapshot(enabled: false, peers: [GlancePeerRef(accountId: 1, peerId: 10, title: "Anna")]) }
        let suggested = try await PeerEntityQuery().suggestedEntities()
        XCTAssertTrue(suggested.isEmpty)
    }
}

@available(iOS 16.0, macOS 13.0, *)
final class IntentPerformTests: XCTestCase {
    override func tearDown() {
        NanogramIntentEnvironment.snapshotReader = { nil }
        super.tearDown()
    }

    func testOpenChatResolvesAPeerAndCallsTheApp() async throws {
        NanogramIntentEnvironment.snapshotReader = { snapshot(peers: []) }
        let recorder = Recorder()
        await GlanceIntentBridge.shared.register(handler(recorder: recorder, sendResult: .queued))
        defer {
            Task {
                await GlanceIntentBridge.shared.register(nil)
            }
        }
        _ = try await OpenChatIntent(chat: PeerEntity(id: "2:42", title: "Chat")).perform()
        let opened = await recorder.opened
        XCTAssertEqual(opened, ["2:42"])
    }

    func testOpenChatRefusesWhenTheFeatureIsOff() async {
        NanogramIntentEnvironment.snapshotReader = { snapshot(enabled: false, peers: []) }
        do {
            _ = try await OpenChatIntent(chat: PeerEntity(id: "2:42", title: "Chat")).perform()
            XCTFail("expected an error")
        } catch let error as NanogramIntentError {
            XCTAssertEqual(String(describing: error), String(describing: NanogramIntentError.notEnabled))
        } catch {
            XCTFail("unexpected error")
        }
    }

    func testSendToSavedMessagesRefusesWhilePasscodeLocked() async {
        NanogramIntentEnvironment.snapshotReader = { snapshot(peers: []) }
        let recorder = Recorder()
        await GlanceIntentBridge.shared.register(handler(recorder: recorder, sendResult: .locked))
        defer {
            Task {
                await GlanceIntentBridge.shared.register(nil)
            }
        }
        do {
            _ = try await SendToSavedMessagesIntent(text: "hello").perform()
            XCTFail("expected an error")
        } catch let error as NanogramIntentError {
            XCTAssertEqual(String(describing: error), String(describing: NanogramIntentError.locked))
        } catch {
            XCTFail("unexpected error")
        }
    }

    func testSendToSavedMessagesQueuesWhenUnlocked() async throws {
        NanogramIntentEnvironment.snapshotReader = { snapshot(peers: []) }
        let recorder = Recorder()
        await GlanceIntentBridge.shared.register(handler(recorder: recorder, sendResult: .queued))
        defer {
            Task {
                await GlanceIntentBridge.shared.register(nil)
            }
        }
        _ = try await SendToSavedMessagesIntent(text: "  hello  ").perform()
        let sent = await recorder.sent
        XCTAssertEqual(sent, ["hello"])
    }
}
