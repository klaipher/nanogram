import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// Chat-list loader that answers every page with "nothing more".
struct CoreFakeChatListLoader: ChatListLoader {
    func loadChats(chatList: ChatList, limit: Int) async throws {
        throw TDError(code: 404, message: "Not Found")
    }
    func downloadFile(fileId: Int, priority: Int) async throws -> File { throw CancellationError() }
    func cancelDownloadFile(fileId: Int) async throws {}
}

/// While the app is inactive the system does not redraw it, so updates go into the caches and
/// the stores project once when it is active again.
@MainActor
final class CoreProjectionPauseTests: XCTestCase {
    private final class Delegate: TDClientLifecycleDelegate {
        func tdClient(_ client: TDClient, didFetchMe me: User) {}
        func tdClient(_ client: TDClient, didDestroyItselfWithReason reason: TDClientDestroyReason) {}
    }

    private func folders(position: Int) -> Update {
        .updateChatFolders(UpdateChatFolders(areTagsEnabled: false, chatFolders: [], mainChatListPosition: position))
    }

    private func readOutbox(_ id: Int64) -> Update {
        .updateChatReadOutbox(UpdateChatReadOutbox(chatId: CoreFixtures.chatId, lastReadOutboxMessageId: id))
    }

    func testChatListDefersProjectionUntilActive() {
        let store = ChatListStore(loader: CoreFakeChatListLoader())
        let before = store.debugReprojectCount
        store.setProjectionPaused(true)
        store.handle(folders(position: 1))
        store.handle(folders(position: 2))
        XCTAssertEqual(store.debugReprojectCount, before)

        store.setProjectionPaused(false)
        XCTAssertEqual(store.debugReprojectCount, before + 1)
    }

    func testChatListResumeWithoutUpdatesDoesNotProject() {
        let store = ChatListStore(loader: CoreFakeChatListLoader())
        let before = store.debugReprojectCount
        store.setProjectionPaused(true)
        store.setProjectionPaused(false)
        XCTAssertEqual(store.debugReprojectCount, before)
    }

    func testHistoryAppliesUpdatesButDefersProjection() {
        let store = CoreFixtures.historyStore(loader: CoreFakeHistoryLoader())
        let before = store.debugReprojectCount
        store.setProjectionPaused(true)
        store.handle(readOutbox(5))
        XCTAssertEqual(store.lastReadOutboxMessageId, 5)
        XCTAssertEqual(store.debugReprojectCount, before)

        store.setProjectionPaused(false)
        XCTAssertEqual(store.debugReprojectCount, before + 1)
    }

    /// Music tapped just before the wrist went down still starts when its file arrives.
    func testHistoryKeepsProjectingWhilePlaybackWaitsForItsFile() {
        let store = CoreFixtures.historyStore(loader: CoreFakeHistoryLoader())
        store.audioPlayback.toggle(audio: AudioVisual(
            audioFileId: 9, duration: 1, title: "t", performer: "", albumArt: nil, caption: "", localPath: nil
        ))
        XCTAssertEqual(store.audioPlayback.state, .preparing(audioFileId: 9))
        let before = store.debugReprojectCount
        store.setProjectionPaused(true)
        store.handle(readOutbox(6))
        XCTAssertEqual(store.debugReprojectCount, before + 1)
    }

    func testSceneInactivePausesTheOpenChat() {
        let client = TDClient(account: CoreAccountFixtures.account(), makeClient: { _ in
            fatalError("TDLib is not used here")
        }, delegate: Delegate())
        let store = CoreFixtures.historyStore(loader: CoreFakeHistoryLoader())
        client.setActiveHistory(store)
        let before = store.debugReprojectCount

        client.setSceneActive(false)
        store.handle(readOutbox(7))
        XCTAssertEqual(store.debugReprojectCount, before)

        client.setSceneActive(true)
        XCTAssertEqual(store.debugReprojectCount, before + 1)
    }

    func testChatOpenedWhileInactiveStartsPaused() {
        let client = TDClient(account: CoreAccountFixtures.account(), makeClient: { _ in
            fatalError("TDLib is not used here")
        }, delegate: Delegate())
        client.setSceneActive(false)
        let store = CoreFixtures.historyStore(loader: CoreFakeHistoryLoader())
        client.setActiveHistory(store)
        let before = store.debugReprojectCount
        store.handle(readOutbox(8))
        XCTAssertEqual(store.debugReprojectCount, before)
    }
}
