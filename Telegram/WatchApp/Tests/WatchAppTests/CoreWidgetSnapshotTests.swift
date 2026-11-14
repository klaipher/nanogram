import XCTest
@testable import tgwatch_Watch_App

/// IOS-WATCH-WIDGET-1: the unread summary the app writes to the App Group for the widget extension.
@MainActor
final class CoreWidgetSnapshotTests: XCTestCase {
    private func chat(_ title: String, unread: Int, muted: Bool = false) -> UnreadChatInput {
        UnreadChatInput(title: title, unread: unread, isMuted: muted)
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: builder

    func testTotalCountsUnmutedChatsOnlyAndTopChatsFollowListOrder() {
        let snapshot = WatchUnreadSnapshotBuilder.make(
            ordered: [chat("A", unread: 0), chat("B", unread: 5), chat("C", unread: 9, muted: true),
                      chat("D", unread: 2), chat("E", unread: 7)],
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(snapshot.totalUnread, 14)
        XCTAssertEqual(snapshot.topChats, [.init(title: "B", unread: 5), .init(title: "D", unread: 2)])
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.version, WatchUnreadSnapshot.currentVersion)
    }

    func testNothingUnreadGivesAnEmptySummary() {
        let snapshot = WatchUnreadSnapshotBuilder.make(ordered: [chat("A", unread: 0)], now: Date())
        XCTAssertEqual(snapshot.totalUnread, 0)
        XCTAssertTrue(snapshot.topChats.isEmpty)
        XCTAssertEqual(snapshot.relevanceScore, 0)
    }

    func testLongTitlesAreCut() {
        let long = String(repeating: "x", count: 100)
        let snapshot = WatchUnreadSnapshotBuilder.make(ordered: [chat(long, unread: 1)], now: Date())
        XCTAssertEqual(snapshot.topChats.first?.title.count, WatchUnreadSnapshotBuilder.maximumTitleLength)
    }

    func testBadgeAndRelevance() {
        func snap(_ n: Int) -> WatchUnreadSnapshot { WatchUnreadSnapshot(generatedAt: Date(), totalUnread: n, topChats: []) }
        XCTAssertEqual(snap(7).badgeText, "7")
        XCTAssertEqual(snap(99).badgeText, "99")
        XCTAssertEqual(snap(100).badgeText, "99+")
        XCTAssertEqual(snap(0).relevanceScore, 0)
        XCTAssertEqual(snap(2).relevanceScore, 40)
        XCTAssertEqual(snap(1_000).relevanceScore, 100)
    }

    func testTheSnapshotCarriesNoMessageText() throws {
        let data = try JSONEncoder().encode(WatchUnreadSnapshot(generatedAt: Date(), totalUnread: 1, topChats: [.init(title: "T", unread: 1)]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "generatedAt", "totalUnread", "topChats"])
    }

    // MARK: store

    func testStoreRoundTrips() throws {
        let store = WatchUnreadSnapshotStore(directory: try tempDirectory())
        let snapshot = WatchUnreadSnapshot(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), totalUnread: 4,
                                           topChats: [.init(title: "Mum", unread: 4)])
        XCTAssertTrue(store.write(snapshot))
        XCTAssertEqual(store.read(), snapshot)
    }

    func testStoreWithoutAnAppGroupIsAQuietNoOp() {
        let store = WatchUnreadSnapshotStore(directory: nil)
        XCTAssertFalse(store.isAvailable)
        XCTAssertFalse(store.write(WatchUnreadSnapshot(generatedAt: Date(), totalUnread: 1, topChats: [])))
        XCTAssertNil(store.read())
    }

    func testStoreIgnoresAFileFromANewerFormat() throws {
        let dir = try tempDirectory()
        let json = #"{"version":99,"generatedAt":1,"totalUnread":3,"topChats":[]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent(WatchUnreadSnapshotStore.fileName))
        XCTAssertNil(WatchUnreadSnapshotStore(directory: dir).read())
    }

    func testStoreIgnoresGarbage() throws {
        let dir = try tempDirectory()
        try Data("nope".utf8).write(to: dir.appendingPathComponent(WatchUnreadSnapshotStore.fileName))
        XCTAssertNil(WatchUnreadSnapshotStore(directory: dir).read())
    }

    // MARK: publisher

    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    private func publisher(directory: URL?, clock: Clock, reloads: ReloadCounter) -> WidgetSnapshotPublisher {
        WidgetSnapshotPublisher(
            store: WatchUnreadSnapshotStore(directory: directory),
            reload: { reloads.count += 1 },
            minimumInterval: 15,
            coalesceDelay: .milliseconds(20),
            now: { clock.date }
        )
    }

    private final class ReloadCounter: @unchecked Sendable { var count = 0 }

    func testPublishWritesAndReloadsOnce() throws {
        let dir = try tempDirectory()
        let clock = Clock(), reloads = ReloadCounter()
        let p = publisher(directory: dir, clock: clock, reloads: reloads)
        let snap = WatchUnreadSnapshot(generatedAt: clock.date, totalUnread: 2, topChats: [])
        XCTAssertTrue(p.publish(snap))
        XCTAssertEqual(reloads.count, 1)
        XCTAssertEqual(WatchUnreadSnapshotStore(directory: dir).read(), snap)
    }

    func testSameContentIsNotWrittenAgain() throws {
        let clock = Clock(), reloads = ReloadCounter()
        let p = publisher(directory: try tempDirectory(), clock: clock, reloads: reloads)
        XCTAssertTrue(p.publish(WatchUnreadSnapshot(generatedAt: clock.date, totalUnread: 2, topChats: [])))
        clock.date.addTimeInterval(60)
        XCTAssertFalse(p.publish(WatchUnreadSnapshot(generatedAt: clock.date, totalUnread: 2, topChats: [])))
        XCTAssertEqual(reloads.count, 1, "widget reloads are budgeted")
    }

    func testChangesWithinTheIntervalWaitButForceGoesThrough() throws {
        let clock = Clock(), reloads = ReloadCounter()
        let p = publisher(directory: try tempDirectory(), clock: clock, reloads: reloads)
        XCTAssertTrue(p.publish(WatchUnreadSnapshot(generatedAt: clock.date, totalUnread: 1, topChats: [])))
        clock.date.addTimeInterval(5)
        let changed = WatchUnreadSnapshot(generatedAt: clock.date, totalUnread: 2, topChats: [])
        XCTAssertFalse(p.publish(changed), "too soon after the last write")
        XCTAssertTrue(p.publish(changed, force: true))
        clock.date.addTimeInterval(20)
        XCTAssertTrue(p.publish(WatchUnreadSnapshot(generatedAt: clock.date, totalUnread: 3, topChats: [])))
    }

    func testNothingIsWrittenWithoutAnAppGroup() {
        let clock = Clock(), reloads = ReloadCounter()
        let p = publisher(directory: nil, clock: clock, reloads: reloads)
        XCTAssertFalse(p.isAvailable)
        XCTAssertFalse(p.publish(WatchUnreadSnapshot(generatedAt: clock.date, totalUnread: 1, topChats: [])))
        XCTAssertEqual(reloads.count, 0)
    }

    func testBurstOfRequestsBuildsOneSnapshot() async throws {
        let dir = try tempDirectory()
        let clock = Clock(), reloads = ReloadCounter()
        let p = publisher(directory: dir, clock: clock, reloads: reloads)
        var builds = 0
        for _ in 0..<5 {
            p.requestPublish { builds += 1; return [UnreadChatInput(title: "A", unread: 3, isMuted: false)] }
        }
        let written = await coreWait { WatchUnreadSnapshotStore(directory: dir).read() != nil }
        XCTAssertTrue(written)
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(WatchUnreadSnapshotStore(directory: dir).read()?.totalUnread, 3)
    }

    func testPublishNowBypassesTheInterval() throws {
        let clock = Clock(), reloads = ReloadCounter()
        let p = publisher(directory: try tempDirectory(), clock: clock, reloads: reloads)
        p.publishNow(inputs: [UnreadChatInput(title: "A", unread: 1, isMuted: false)])
        clock.date.addTimeInterval(1)
        p.publishNow(inputs: [UnreadChatInput(title: "A", unread: 2, isMuted: false)])
        XCTAssertEqual(reloads.count, 2)
    }

    // MARK: project wiring

    func testFlagShipsOnAndTheWidgetIsInTheDefaultProject() throws {
        XCTAssertTrue(WatchFeature.widgetSnapshot.defaultValue)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("WatchWidgetExtension"), "the widget is part of the default project")
        XCTAssertTrue(project.contains("com.apple.widgetkit-extension"))
        XCTAssertTrue(project.contains("$(TG_WATCH_BUNDLE_ID).widget"), "the widget id follows the watch app id")
    }
}
