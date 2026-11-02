import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// The chat list projects from an ordered per-list index instead of scanning and sorting the
/// whole cache. After any sequence of updates its rows and pills must equal the full-scan
/// projection over the same cache.
@MainActor
final class CoreChatListIndexTests: XCTestCase {
    /// A TDLib chat with every field set (SampleDecoder), then the fields under test replaced.
    private func chat(id: Int64, positions: [ChatPosition], unread: Int) throws -> Chat {
        let sample = try Chat(from: SampleDecoder(typeName: "Chat", depth: 0))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        json["id"] = id
        json["title"] = "Chat \(id)"
        json["unread_count"] = unread
        json["positions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(positions))
        json["type"] = ["@type": "chatTypePrivate", "user_id": id]
        return try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private struct Rng {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
    }

    private let lists: [ChatList] = [.chatListMain, .chatListArchive] + (2...5).map { .chatListFolder(ChatListFolder(chatFolderId: $0)) }
    private let folderInfos: [ChatFolderInfo] = (2...5).map {
        ChatFolderInfo(colorId: -1, hasMyInviteLinks: false, icon: ChatFolderIcon(name: "Custom"), id: $0, isShareable: false,
                       name: ChatFolderName(animateCustomEmoji: false, text: FormattedText(entities: [], text: "F\($0)")))
    }

    private func assertMatchesFullScan(_ store: ChatListStore, mainPosition: Int, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = ChatRow.project(
            chats: store.debugChatCache, userNames: [:], selfUserId: nil,
            currentFolder: store.currentFolder, limit: 30, fileLocals: store.debugFiles
        )
        XCTAssertEqual(store.chats, expected, step, file: file, line: line)
        let pills = FolderPill.project(chats: store.debugChatCache, folders: folderInfos,
                                       mainChatListPosition: mainPosition, currentFolder: store.currentFolder)
        XCTAssertEqual(store.pills, pills, step, file: file, line: line)
    }

    func testRandomUpdatesMatchTheFullScan() throws {
        let store = ChatListStore(loader: CoreFakeChatListLoader())
        store.handle(.updateChatFolders(UpdateChatFolders(areTagsEnabled: false, chatFolders: folderInfos, mainChatListPosition: 1)))
        var rng = Rng(state: 42)
        // Orders are unique within a list, as TDLib's are: a random high part plus the chat id.
        func order(_ id: Int64) -> TdInt64 { TdInt64(Int64(1 + rng.next(1_000_000)) * 10_000 + id) }
        let chatCount = 300
        for i in 0..<chatCount {
            let id = Int64(i + 1)
            var positions = [ChatPosition(isPinned: false, list: .chatListMain, order: order(id), source: nil)]
            for list in lists.dropFirst() where rng.next(3) == 0 {
                positions.append(ChatPosition(isPinned: false, list: list, order: order(id), source: nil))
            }
            store.handle(.updateNewChat(UpdateNewChat(chat: try chat(id: id, positions: positions, unread: rng.next(4)))))
        }
        assertMatchesFullScan(store, mainPosition: 1, "initial")

        for step in 0..<1500 {
            let id = Int64(1 + rng.next(chatCount))
            let list = lists[rng.next(lists.count)]
            switch rng.next(7) {
            case 0, 1:
                store.handle(.updateChatPosition(UpdateChatPosition(chatId: id, position: ChatPosition(isPinned: false, list: list, order: order(id), source: nil))))
            case 2:
                // Order 0 removes the chat from the list.
                store.handle(.updateChatPosition(UpdateChatPosition(chatId: id, position: ChatPosition(isPinned: false, list: list, order: 0, source: nil))))
            case 3:
                store.handle(.updateChatReadInbox(UpdateChatReadInbox(chatId: id, lastReadInboxMessageId: 1, unreadCount: rng.next(10))))
            case 4:
                // TDLib follows a chat's addition to a list with its position.
                store.handle(.updateChatAddedToList(UpdateChatAddedToList(chatId: id, chatList: list)))
                store.handle(.updateChatPosition(UpdateChatPosition(chatId: id, position: ChatPosition(isPinned: false, list: list, order: order(id), source: nil))))
            case 5:
                store.handle(.updateChatRemovedFromList(UpdateChatRemovedFromList(chatId: id, chatList: list)))
            default:
                store.setCurrentFolder(lists[rng.next(lists.count)])
            }
            assertMatchesFullScan(store, mainPosition: 1, "step \(step)")
            if store.chats != ChatRow.project(chats: store.debugChatCache, userNames: [:], selfUserId: nil,
                                              currentFolder: store.currentFolder, limit: 30, fileLocals: store.debugFiles) {
                return  // one failure is enough
            }
        }
    }

    /// A chat just added to a list sits at order 0, at the bottom, until its position arrives.
    func testJustAddedChatSitsAtTheBottom() throws {
        let store = ChatListStore(loader: CoreFakeChatListLoader())
        for id in 1...3 {
            let position = ChatPosition(isPinned: false, list: .chatListMain, order: TdInt64(Int64(100 * id)), source: nil)
            store.handle(.updateNewChat(UpdateNewChat(chat: try chat(id: Int64(id), positions: [position], unread: 0))))
        }
        store.handle(.updateChatAddedToList(UpdateChatAddedToList(chatId: 2, chatList: .chatListArchive)))
        store.setCurrentFolder(.chatListArchive)
        XCTAssertEqual(store.chats.map(\.id), [2])
        XCTAssertEqual(store.chats.first?.order, 0)
    }
}
