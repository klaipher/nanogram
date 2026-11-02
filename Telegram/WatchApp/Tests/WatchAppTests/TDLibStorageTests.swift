import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// Where each account's TDLib data goes. The database (td.binlog holds the auth keys) must stay
/// in Application Support; downloads may live in Caches, which the system can purge.
final class TDLibStorageLayoutTests: XCTestCase {
    // XCTest makes a new instance per test, so each test gets its own directory.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TDLibStorageTests-\(UUID().uuidString)", isDirectory: true)
    private let fm = FileManager.default

    private var roots: TDLibStorage.Roots {
        TDLibStorage.Roots(
            applicationSupport: root.appendingPathComponent("Application Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        // A test may leave a directory read-only.
        if let paths = fm.enumerator(atPath: root.path) {
            for case let path as String in paths {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
            }
        }
        try? fm.removeItem(at: root)
    }

    private func databaseDirectory(_ id: UUID) -> URL {
        roots.applicationSupport.appendingPathComponent("tdlib/\(id.uuidString)", isDirectory: true)
    }

    private func cachesDirectory(_ id: UUID) -> URL {
        roots.caches.appendingPathComponent("tdlib/\(id.uuidString)", isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func testNewAccountKeepsDatabaseInApplicationSupportAndFilesInCaches() {
        let id = UUID()
        let layout = TDLibStorage.prepareLayout(accountId: id, roots: roots)

        XCTAssertEqual(layout.databaseDirectory.standardizedFileURL, databaseDirectory(id).standardizedFileURL)
        XCTAssertEqual(layout.filesDirectory.standardizedFileURL, cachesDirectory(id).standardizedFileURL)
        XCTAssertTrue(layout.filesArePurgeable)
        XCTAssertTrue(isDirectory(layout.databaseDirectory))
        XCTAssertTrue(isDirectory(layout.filesDirectory))
    }

    /// The layout is decided once: later launches keep it, even after the system purged Caches.
    func testCachesLayoutSurvivesAPurgedCachesDirectory() throws {
        let id = UUID()
        _ = TDLibStorage.prepareLayout(accountId: id, roots: roots)
        // TDLib's first run.
        try Data("binlog".utf8).write(to: databaseDirectory(id).appendingPathComponent("td.binlog"))
        try fm.removeItem(at: roots.caches)

        let layout = TDLibStorage.prepareLayout(accountId: id, roots: roots)
        XCTAssertEqual(layout.filesDirectory.standardizedFileURL, cachesDirectory(id).standardizedFileURL)
        XCTAssertTrue(isDirectory(layout.filesDirectory))
    }

    /// An account TDLib already ran in keeps its downloads where its file database expects them.
    func testExistingAccountKeepsItsFilesInTheDatabaseDirectory() throws {
        let id = UUID()
        let dbDir = databaseDirectory(id)
        try fm.createDirectory(at: dbDir.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data("binlog".utf8).write(to: dbDir.appendingPathComponent("td.binlog"))
        let photo = dbDir.appendingPathComponent("photos/1.jpg")
        try Data("photo".utf8).write(to: photo)

        let layout = TDLibStorage.prepareLayout(accountId: id, roots: roots)

        XCTAssertEqual(layout.filesDirectory.standardizedFileURL, dbDir.standardizedFileURL)
        XCTAssertFalse(layout.filesArePurgeable)
        XCTAssertEqual(try Data(contentsOf: photo), Data("photo".utf8))
        XCTAssertFalse(fm.fileExists(atPath: cachesDirectory(id).path))

        // And stays there on every later launch.
        let again = TDLibStorage.prepareLayout(accountId: id, roots: roots)
        XCTAssertEqual(again.filesDirectory.standardizedFileURL, dbDir.standardizedFileURL)
    }

    func testExistingTestDcAccountKeepsItsLayout() throws {
        let id = UUID()
        let dbDir = databaseDirectory(id)
        try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try Data("binlog".utf8).write(to: dbDir.appendingPathComponent("td_test.binlog"))

        let layout = TDLibStorage.prepareLayout(accountId: id, roots: roots)
        XCTAssertEqual(layout.filesDirectory.standardizedFileURL, dbDir.standardizedFileURL)
    }

    /// Leftovers without a binlog (a logout keeps downloads) are still data TDLib may scan.
    func testDirectoryWithOnlyDownloadsKeepsItsLayout() throws {
        let id = UUID()
        let dbDir = databaseDirectory(id)
        try fm.createDirectory(at: dbDir.appendingPathComponent("documents"), withIntermediateDirectories: true)

        let layout = TDLibStorage.prepareLayout(accountId: id, roots: roots)
        XCTAssertEqual(layout.filesDirectory.standardizedFileURL, dbDir.standardizedFileURL)
    }

    /// If the choice cannot be recorded, TDLib must not start with files in Caches: the next
    /// launch would find a used directory and pick the other layout.
    func testUnrecordableChoiceFallsBackToTheDatabaseDirectory() throws {
        let id = UUID()
        let dbDir = databaseDirectory(id)
        try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dbDir.path)

        let layout = TDLibStorage.prepareLayout(accountId: id, roots: roots)
        XCTAssertEqual(layout.filesDirectory.standardizedFileURL, dbDir.standardizedFileURL)

        // Writable again and used by TDLib: still the same layout.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dbDir.path)
        try Data("binlog".utf8).write(to: dbDir.appendingPathComponent("td.binlog"))
        let again = TDLibStorage.prepareLayout(accountId: id, roots: roots)
        XCTAssertEqual(again.filesDirectory.standardizedFileURL, dbDir.standardizedFileURL)
    }

    func testAccountsDoNotShareDirectories() {
        let a = TDLibStorage.prepareLayout(accountId: UUID(), roots: roots)
        let b = TDLibStorage.prepareLayout(accountId: UUID(), roots: roots)
        XCTAssertNotEqual(a.databaseDirectory, b.databaseDirectory)
        XCTAssertNotEqual(a.filesDirectory, b.filesDirectory)
    }

    /// Removing an account must not leave its media behind in Caches.
    func testRemoveStorageDeletesBothDirectories() throws {
        let id = UUID()
        let other = UUID()
        let layout = TDLibStorage.prepareLayout(accountId: id, roots: roots)
        let kept = TDLibStorage.prepareLayout(accountId: other, roots: roots)
        try fm.createDirectory(at: layout.filesDirectory.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: layout.filesDirectory.appendingPathComponent("photos/1.jpg"))

        TDLibStorage.removeStorage(accountId: id, roots: roots)

        XCTAssertFalse(fm.fileExists(atPath: layout.databaseDirectory.path))
        XCTAssertFalse(fm.fileExists(atPath: layout.filesDirectory.path))
        XCTAssertTrue(isDirectory(kept.databaseDirectory))
        XCTAssertTrue(isDirectory(kept.filesDirectory))
    }

    /// Existing installs keep finding their database where earlier builds put it.
    func testProductionDatabaseDirectoryIsUnchanged() throws {
        let id = UUID()
        let earlier = try XCTUnwrap(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("tdlib", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        XCTAssertEqual(
            TDLibStorage.databaseDirectory(accountId: id, roots: .production).standardizedFileURL.path,
            earlier.standardizedFileURL.path
        )
    }
}

/// The explicit trim TDLib's daily optimizer does not do.
final class TDLibStorageOptimizationTests: XCTestCase {
    private func json(_ query: OptimizeStorage) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(DTO(query, encoder: encoder))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testQueryMatchesTheTDLibSchema() throws {
        let query = try json(TDLibStorageOptimization.query())
        XCTAssertEqual(query["@type"] as? String, "optimizeStorage")
        XCTAssertEqual(query["size"] as? Int, 50 * 1024 * 1024)
        XCTAssertEqual(query["ttl"] as? Int, 7 * 24 * 60 * 60)
        XCTAssertEqual(query["count"] as? Int, 5000)
        XCTAssertEqual(query["immunity_delay"] as? Int, -1)
        XCTAssertEqual(query["chat_ids"] as? [Int], [])
        XCTAssertEqual(query["exclude_chat_ids"] as? [Int], [])
        XCTAssertEqual(query["return_deleted_file_statistics"] as? Bool, true)
        XCTAssertEqual(query["chat_limit"] as? Int, 0)
        XCTAssertEqual(Set(query.keys), [
            "@type", "size", "ttl", "count", "immunity_delay", "file_types", "chat_ids",
            "exclude_chat_ids", "return_deleted_file_statistics", "chat_limit",
        ])
    }

    /// TDLib's optimizer skips stickers, thumbnails and profile photos unless they are named;
    /// the sticker picker downloads every sticker it shows.
    func testQueryNamesTheTypesTDLibKeepsByDefault() throws {
        let query = try json(TDLibStorageOptimization.query())
        let types = try XCTUnwrap(query["file_types"] as? [[String: Any]]).compactMap { $0["@type"] as? String }
        for type in ["fileTypeSticker", "fileTypeThumbnail", "fileTypeProfilePhoto",
                     "fileTypePhoto", "fileTypeVideo", "fileTypeVoiceNote", "fileTypeVideoNote",
                     "fileTypeAnimation", "fileTypeDocument", "fileTypeAudio"] {
            XCTAssertTrue(types.contains(type), type)
        }
        XCTAssertFalse(types.contains("fileTypeSecretThumbnail"))
        XCTAssertEqual(types.count, Set(types).count)
    }

    func testStatisticsDecode() throws {
        let json = #"{"@type":"storageStatistics","size":1234,"count":5,"by_chat":[],"@extra":"x"}"#
        let decoder = JSONDecoder()
        let stats = try TDLibStorageOptimization.decodeResult(Data(json.utf8), decoder: decoder)
        XCTAssertEqual(stats.size, 1234)
        XCTAssertEqual(stats.count, 5)
    }

    func testErrorDecodes() {
        let json = #"{"@type":"error","code":401,"message":"Unauthorized"}"#
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try TDLibStorageOptimization.decodeResult(Data(json.utf8), decoder: decoder)) { error in
            XCTAssertEqual((error as? TDError)?.code, 401)
        }
    }

    /// Out-of-range numbers from TDLib must not trap.
    func testHugeStatisticsDoNotTrap() throws {
        let json = #"{"@type":"storageStatistics","size":9007199254740991,"count":2147483647,"by_chat":[]}"#
        let decoder = JSONDecoder()
        let stats = try TDLibStorageOptimization.decodeResult(Data(json.utf8), decoder: decoder)
        XCTAssertEqual(stats.size, 9_007_199_254_740_991)
    }
}

/// Runs the real TDLib JSON parser: a request it cannot parse fails with a parse error
/// before any state check, so "needs setTdlibParameters" proves the shape is valid.
final class TDLibStorageOptimizationSchemaTests: XCTestCase {
    nonisolated(unsafe) private static let client = SharedTestTDLib.manager.createClient { _, _ in }

    func testTDLibParsesTheQuery() async throws {
        do {
            _ = try await TDLibStorageOptimization.run(client: Self.client)
            XCTFail("TDLib answered optimizeStorage without parameters")
        } catch let error as TDError {
            XCTAssertFalse(error.message.contains("parse"), error.message)
            XCTAssertTrue(error.message.contains("setTdlibParameters"), error.message)
        }
    }
}

/// The trim runs at most once per interval per account, across launches.
final class TDLibStorageOptimizationScheduleTests: XCTestCase {
    private let suite = "TDLibStorageOptimizationScheduleTests-\(UUID().uuidString)"
    private var defaults: UserDefaults {
        UserDefaults(suiteName: suite) ?? .standard
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testDueOnFirstRunThenWaitsForTheInterval() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let schedule = TDLibStorageOptimizationSchedule(defaults: defaults, interval: 3600, now: { now })
        let id = UUID()

        XCTAssertTrue(schedule.isDue(accountId: id))
        schedule.markRun(accountId: id)
        XCTAssertFalse(schedule.isDue(accountId: id))

        now += 3599
        XCTAssertFalse(schedule.isDue(accountId: id))
        now += 1
        XCTAssertTrue(schedule.isDue(accountId: id))
    }

    func testRemembersAcrossInstances() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = UUID()
        TDLibStorageOptimizationSchedule(defaults: defaults, interval: 3600, now: { now }).markRun(accountId: id)
        XCTAssertFalse(TDLibStorageOptimizationSchedule(defaults: defaults, interval: 3600, now: { now }).isDue(accountId: id))
    }

    func testAccountsAreIndependent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let schedule = TDLibStorageOptimizationSchedule(defaults: defaults, interval: 3600, now: { now })
        let a = UUID()
        schedule.markRun(accountId: a)
        XCTAssertTrue(schedule.isDue(accountId: UUID()))
    }

    /// A clock set back must not block the trim for as long as it moved.
    func testClockMovedBackIsDue() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let schedule = TDLibStorageOptimizationSchedule(defaults: defaults, interval: 3600, now: { now })
        let id = UUID()
        schedule.markRun(accountId: id)
        now -= 86400
        XCTAssertTrue(schedule.isDue(accountId: id))
    }

    func testClearedRunIsDueAgain() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let schedule = TDLibStorageOptimizationSchedule(defaults: defaults, interval: 3600, now: { now })
        let id = UUID()
        schedule.markRun(accountId: id)
        schedule.clearRun(accountId: id)
        XCTAssertTrue(schedule.isDue(accountId: id))
    }
}

/// Options sent once an account is ready, beyond the storage optimizer.
final class TDLibDiskOptionsTests: XCTestCase {
    private func options() throws -> [String: [String: Any]] {
        let encoder = JSONEncoder()
        var result: [String: [String: Any]] = [:]
        for option in TDLibReadyOptions.all {
            let data = try encoder.encode(DTO(option, encoder: encoder))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let name = try XCTUnwrap(json["name"] as? String)
            result[name] = try XCTUnwrap(json["value"] as? [String: Any])
        }
        return result
    }

    /// The watch shows no network statistics; persisting them writes the binlog every few KB.
    func testPersistentNetworkStatisticsAreOff() throws {
        let value = try XCTUnwrap(try options()["disable_persistent_network_statistics"])
        XCTAssertEqual(value["@type"] as? String, "optionValueBoolean")
        XCTAssertEqual(value["value"] as? Bool, true)
    }

    /// Rejected on purpose, each with a visible or account-wide effect:
    /// - disable_time_adjustment_protection: wrong times after a launch until the server answers;
    /// - disable_network_statistics: also changes TDLib's network-type detection;
    /// - disable_top_chats, disable_contact_registered_notifications: account settings synced to
    ///   the user's other devices;
    /// - ignore_inline_thumbnails: thumbnails downloaded again over the watch's slow link;
    /// - store_all_files_in_files_directory: applies only from the next TDLib start, stranding
    ///   the files of the first session.
    func testOptionsWithTradeoffsStayOff() throws {
        let names = Set(try options().keys)
        for rejected in ["disable_time_adjustment_protection", "disable_network_statistics", "disable_top_chats",
                         "disable_contact_registered_notifications", "ignore_inline_thumbnails",
                         "store_all_files_in_files_directory", "disable_animated_emoji"] {
            XCTAssertFalse(names.contains(rejected), rejected)
        }
    }
}
