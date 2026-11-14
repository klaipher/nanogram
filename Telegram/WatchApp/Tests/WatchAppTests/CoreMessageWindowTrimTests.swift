import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// WATCH-LIST-1: window trimming, progress-only file update gating and the cached sort.
final class CoreMessageWindowTrimTests: XCTestCase {
    private func window(ids: [Int64], tail: Bool = true) throws -> MessageWindow {
        var w = MessageWindow(anchor: .tail, halfLimit: 15, unreadDividerAfterId: nil)
        w.extendInitial(try ids.map { CachedMessage(try CoreFixtures.message(id: $0)) }, chatTailId: tail ? ids.max() : nil)
        return w
    }

    func testTrimNewestKeepsTheOlderMessagesAndLeavesTheTail() throws {
        var w = try window(ids: Array(1...10))
        XCTAssertTrue(w.reachesChatTail)
        let dropped = w.trim(toLimit: 6, droppingFrom: .newest)
        XCTAssertEqual(dropped, 4)
        XCTAssertEqual(w.cache.keys.sorted(), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(w.loadedHighestId, 6)
        XCTAssertEqual(w.loadedLowestId, 1)
        XCTAssertFalse(w.reachesChatTail, "the window no longer reaches the tail, so loadNewer can refill it")
    }

    func testTrimOldestKeepsTheNewerMessagesAndReopensOlderHistory() throws {
        var w = try window(ids: Array(1...10))
        w.markHasOlderFalse()
        let dropped = w.trim(toLimit: 6, droppingFrom: .oldest)
        XCTAssertEqual(dropped, 4)
        XCTAssertEqual(w.cache.keys.sorted(), [5, 6, 7, 8, 9, 10])
        XCTAssertEqual(w.loadedLowestId, 5)
        XCTAssertTrue(w.hasOlder)
        XCTAssertTrue(w.reachesChatTail, "the tail end is untouched")
    }

    func testTrimBelowTheLimitDoesNothing() throws {
        var w = try window(ids: [1, 2, 3])
        let before = w.revision
        XCTAssertEqual(w.trim(toLimit: 3, droppingFrom: .newest), 0)
        XCTAssertEqual(w.trim(toLimit: 100, droppingFrom: .oldest), 0)
        XCTAssertEqual(w.cache.count, 3)
        XCTAssertEqual(w.revision, before)
        XCTAssertTrue(w.reachesChatTail)
        XCTAssertTrue(w.hasOlder)
    }

    func testTrimNeverDropsAMessageThatIsStillSending() throws {
        var w = try window(ids: [1, 2, 3, 4])
        // A message in flight carries a local id at the newest end.
        let pending = CachedMessage(
            id: 900, date: 1_700_000_000, editDate: 0, isOutgoing: true,
            senderId: .messageSenderUser(MessageSenderUser(userId: 1)),
            content: try CachedMessage(try CoreFixtures.message(id: 1)).content,
            sendingState: .pending, replyTo: nil
        )
        w.applySendSucceeded(oldId: 999, message: pending)   // inserts it
        XCTAssertNotNil(w.cache[900])
        w.trim(toLimit: 3, droppingFrom: .newest)
        XCTAssertNotNil(w.cache[900], "a pending send stays")
        XCTAssertEqual(w.cache.count, 3)
        XCTAssertEqual(w.cache.keys.sorted(), [1, 2, 900])
    }

    func testRevisionChangesWithTheMessagesOnly() throws {
        var w = try window(ids: [1, 2])
        let r0 = w.revision
        w.markReachesChatTail()
        XCTAssertEqual(w.revision, r0, "flags are not messages")
        w.applyDelete(ids: [1])
        XCTAssertGreaterThan(w.revision, r0)
    }

    // MARK: file update gate

    private func file(id: Int = 5, downloaded: Int64, expected: Int64 = 1_000, completed: Bool = false,
                      active: Bool = true, path: String = "") throws -> File {
        let json = """
        {"@type":"file","id":\(id),"size":0,"expected_size":\(expected),
         "local":{"@type":"localFile","path":"\(path)","can_be_downloaded":true,"can_be_deleted":false,
                  "is_downloading_active":\(active),"is_downloading_completed":\(completed),
                  "download_offset":0,"downloaded_prefix_size":\(downloaded),"downloaded_size":\(downloaded)},
         "remote":{"@type":"remoteFile","id":"","unique_id":"","is_uploading_active":false,
                   "is_uploading_completed":true,"uploaded_size":0}}
        """
        return try CoreFixtures.tdlibDecoder().decode(File.self, from: Data(json.utf8))
    }

    func testFirstUpdateOfAFileAlwaysGetsThrough() throws {
        var gate = FileUpdateGate()
        XCTAssertTrue(gate.shouldReproject(for: try file(downloaded: 0)))
    }

    func testProgressWithinAStepIsSwallowed() throws {
        var gate = FileUpdateGate()
        XCTAssertTrue(gate.shouldReproject(for: try file(downloaded: 0)))
        for bytes in stride(from: Int64(1), to: 49, by: 4) {
            XCTAssertFalse(gate.shouldReproject(for: try file(downloaded: bytes)), "\(bytes) of 1000 bytes")
        }
        XCTAssertTrue(gate.shouldReproject(for: try file(downloaded: 50)), "5%: next step")
        XCTAssertFalse(gate.shouldReproject(for: try file(downloaded: 60)))
    }

    func testAtMostTwentyStepsPerFile() throws {
        var gate = FileUpdateGate()
        var passed = 0
        for bytes in stride(from: Int64(0), through: 999, by: 1) where gate.shouldReproject(for: try file(downloaded: bytes)) {
            passed += 1
        }
        XCTAssertLessThanOrEqual(passed, FileUpdateGate.steps)
    }

    func testCompletionAlwaysGetsThrough() throws {
        var gate = FileUpdateGate()
        _ = gate.shouldReproject(for: try file(downloaded: 990))
        XCTAssertTrue(gate.shouldReproject(for: try file(downloaded: 1_000, completed: true, active: false, path: "/tmp/a.mp4")))
        XCTAssertFalse(gate.shouldReproject(for: try file(downloaded: 1_000, completed: true, active: false, path: "/tmp/a.mp4")))
    }

    func testStartingAndStoppingADownloadGetsThrough() throws {
        var gate = FileUpdateGate()
        _ = gate.shouldReproject(for: try file(downloaded: 10, active: true))
        XCTAssertTrue(gate.shouldReproject(for: try file(downloaded: 10, active: false)))
    }

    func testFilesAreTrackedSeparately() throws {
        var gate = FileUpdateGate()
        XCTAssertTrue(gate.shouldReproject(for: try file(id: 1, downloaded: 0)))
        XCTAssertTrue(gate.shouldReproject(for: try file(id: 2, downloaded: 0)))
        XCTAssertFalse(gate.shouldReproject(for: try file(id: 1, downloaded: 1)))
    }

    func testFlagsShipOff() {
        XCTAssertFalse(WatchFeature.messageWindowTrim.defaultValue)
        XCTAssertFalse(WatchFeature.fileProgressThrottle.defaultValue)
    }
}

@MainActor
final class CoreChatHistoryTrimStoreTests: XCTestCase {
    private func store(loader: CoreFakeHistoryLoader, windowLimit: Int?, throttle: Bool = false) -> ChatHistoryStore {
        ChatHistoryStore(
            chatId: CoreFixtures.chatId,
            chatType: .chatTypePrivate(ChatTypePrivate(userId: 2)),
            lastReadInboxMessageId: 0,
            unreadCount: 0,
            lastMessageId: nil,
            loader: loader,
            voicePlayback: VoicePlaybackController(backend: CoreFakeVoiceBackend(), decoder: CoreFakeVoiceDecoder()),
            audioPlayback: AudioPlaybackController(backend: CoreFakeAudioBackend()),
            windowLimit: windowLimit,
            throttleFileProgress: throttle
        )
    }

    private func messages(_ ids: [Int64]) throws -> [Message] { try ids.map { try CoreFixtures.message(id: $0) } }

    func testLoadOlderTrimsTheNewestEndWhenTheLimitIsSet() async throws {
        let loader = CoreFakeHistoryLoader()
        await loader.setHistoryResult(.success(try messages([10, 11, 12])))
        let store = store(loader: loader, windowLimit: 5)
        await store.start()
        await loader.setHistoryResult(.success(try messages([7, 8, 9])))
        await store.loadOlder()
        XCTAssertEqual(store.window.cache.keys.sorted(), [7, 8, 9, 10, 11])
        XCTAssertFalse(store.window.reachesChatTail)
        let ids = store.rows.compactMap { row -> Int64? in
            if case .bubble(let b) = row { return b.messageId }
            return nil
        }
        XCTAssertEqual(ids, [7, 8, 9, 10, 11], "rows follow the window")
    }

    func testLoadOlderKeepsEverythingWithoutALimit() async throws {
        let loader = CoreFakeHistoryLoader()
        await loader.setHistoryResult(.success(try messages([10, 11, 12])))
        let store = store(loader: loader, windowLimit: nil)
        await store.start()
        await loader.setHistoryResult(.success(try messages([7, 8, 9])))
        await store.loadOlder()
        XCTAssertEqual(store.window.cache.count, 6)
        XCTAssertTrue(store.window.reachesChatTail)
    }

    func testLoadNewerTrimsTheOldestEnd() async throws {
        let loader = CoreFakeHistoryLoader()
        await loader.setHistoryResult(.success(try messages([10, 11, 12])))
        let store = store(loader: loader, windowLimit: 4)
        await store.start()
        // Trim the newest end first so loadNewer has something to fetch.
        await loader.setHistoryResult(.success(try messages([8, 9])))
        await store.loadOlder()
        XCTAssertFalse(store.window.reachesChatTail)
        await loader.setHistoryResult(.success(try messages([12, 13])))
        await store.loadNewer()
        XCTAssertLessThanOrEqual(store.window.cache.count, 4)
        XCTAssertEqual(store.window.loadedHighestId, 13, "the newer end is kept")
        XCTAssertTrue(store.window.hasOlder)
    }

    func testFileUpdatesDoNotTouchTheWindowSoTheSortedCacheStaysValid() async throws {
        let loader = CoreFakeHistoryLoader()
        await loader.setHistoryResult(.success(try messages([1, 2, 3])))
        let store = store(loader: loader, windowLimit: nil)
        await store.start()
        let revision = store.window.revision
        store.handle(.updateFile(UpdateFile(file: try CoreFixtures.tdlibDecoder().decode(File.self, from: Data(
            #"{"@type":"file","id":77,"size":0,"expected_size":10,"local":{"@type":"localFile","path":"","can_be_downloaded":true,"can_be_deleted":false,"is_downloading_active":true,"is_downloading_completed":false,"download_offset":0,"downloaded_prefix_size":1,"downloaded_size":1},"remote":{"@type":"remoteFile","id":"","unique_id":"","is_uploading_active":false,"is_uploading_completed":true,"uploaded_size":0}}"#.utf8
        )))))
        XCTAssertEqual(store.window.revision, revision, "a file update never touches the window")
    }
}
