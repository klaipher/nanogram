import Foundation
import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

/// An extension (`removeDatabaseOnError: false`) that finds no atomic state builds one in memory
/// (AccountManagerExtensionOpenTests). That session must stay read-only for the app's state: the app
/// decides on its first launch whether it is a fresh installation from "no atomic-state and empty
/// legacy tables", and resets the keychain's local secrets (an old passcode lock, wallet secrets) only
/// then. An extension that wrote either one first, e.g. the Share extension's lock screen resolving a
/// passcode the keychain kept across a reinstall, made that first launch keep those secrets.
final class AccountManagerExtensionReadOnlyTests: XCTestCase {
    private typealias Types = TelegramAccountManagerTypes

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-manager-extension-read-only-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // No tearDown removal: AccountManager.init creates a MediaBox whose StorageBox opens its SQLite
    // databases under <basePath>/media asynchronously, and removing the directory under it fails that
    // open's assertions (SqliteValueBox.swift) in a later test. Each test has its own directory, and
    // the test simulator is deleted after the run.

    private var atomicStateURL: URL {
        return directory.appendingPathComponent("atomic-state")
    }

    private static let keychainPasscode: PostboxAccessChallengeData = .secured(id: "kept-across-reinstall", kind: .digits4)

    private func open(
        removeDatabaseOnError: Bool,
        isTemporary: Bool,
        prepare: @escaping (Bool) -> Void = { _ in },
        resolve: @escaping (PostboxAccessChallengeData?, Bool) -> PostboxAccessChallengeData? = { current, _ in current }
    ) -> AccountManager<Types> {
        return AccountManager<Types>(basePath: directory.path, isTemporary: isTemporary, isReadOnly: false, useCaches: false, removeDatabaseOnError: removeDatabaseOnError, accessChallenge: AccountManagerAccessChallenge(prepare: { isFreshInstallation in
            prepare(isFreshInstallation)
        }, resolve: { current, allowMigration in
            return resolve(current, allowMigration)
        }, finishInitialization: {
        }))
    }

    /// As ShareExtensionContext.swift, NotificationService.swift and IntentHandler.swift open it.
    private func openAsExtension(resolve: @escaping (PostboxAccessChallengeData?, Bool) -> PostboxAccessChallengeData? = { current, _ in current }) -> AccountManager<Types> {
        return open(removeDatabaseOnError: false, isTemporary: true, resolve: resolve)
    }

    /// The keychain still holds a managed passcode: resolve reports it whatever the tables say.
    private func openAsExtensionWithKeychainPasscode() -> AccountManager<Types> {
        return openAsExtension(resolve: { _, _ in Self.keychainPasscode })
    }

    private func run<T>(_ manager: AccountManager<Types>, _ f: @escaping (AccountManagerModifier<Types>) -> T) -> T {
        let done = expectation(description: "transaction")
        var result: T?
        let disposable = (manager.transaction(f) |> take(1)).start(next: { value in
            result = value
            done.fulfill()
        })
        wait(for: [done], timeout: 10.0)
        disposable.dispose()
        return result!
    }

    /// Reads (or seeds) the legacy tables directly, as a separate connection to `<basePath>/db`.
    private func withLegacyTables<T>(_ f: (AccountManagerRecordTable<Types.Attribute>, AccountManagerMetadataTable<Types.Attribute>) -> T) -> T {
        let queue = Queue()
        var result: T?
        let path = directory.path + "/db"
        queue.sync {
            let valueBox = SqliteValueBox(basePath: path, queue: queue, isTemporary: false, isReadOnly: false, useCaches: false, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in })!
            let metadata = AccountManagerMetadataTable<Types.Attribute>(valueBox: valueBox, table: AccountManagerMetadataTable<Types.Attribute>.tableSpec(0), useCaches: false)
            let records = AccountManagerRecordTable<Types.Attribute>(valueBox: valueBox, table: AccountManagerRecordTable<Types.Attribute>.tableSpec(1), useCaches: false)
            valueBox.begin()
            result = f(records, metadata)
            valueBox.commit()
        }
        return result!
    }

    private func legacyAccessChallenge() -> PostboxAccessChallengeData {
        return withLegacyTables { _, metadata in metadata.getAccessChallengeData() }
    }

    /// What the app's first launch decides: `isFreshInstallation` in `AccountManagerImpl.init`.
    private func appFirstLaunchSeesFreshInstallation() -> Bool {
        var isFresh: Bool?
        let app = open(removeDatabaseOnError: true, isTemporary: false, prepare: { isFresh = $0 })
        _ = app._internalAccountRecordsSync()
        return isFresh!
    }

    // MARK: - Finding 1: an in-memory extension session writes neither the atomic state nor the legacy tables

    func testExtensionDoesNotPersistAnAccessChallengeResolvedFromTheKeychain() {
        let manager = openAsExtensionWithKeychainPasscode()

        // AppLockContextImpl reads it through accessChallengeData(), i.e. getAccessChallengeData().
        let data = run(manager, { $0.getAccessChallengeData() })

        XCTAssertEqual(data, Self.keychainPasscode, "the extension still locks with the keychain's passcode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: atomicStateURL.path), "an extension session without the app's state must not create it")
        XCTAssertEqual(legacyAccessChallenge(), .none, "an extension session without the app's state must not write the legacy tables")
        XCTAssertTrue(appFirstLaunchSeesFreshInstallation(), "the app's first launch must still reset local secrets")
    }

    func testExtensionDoesNotPersistAnAccessChallengeResolvedThroughTheView() {
        let manager = openAsExtensionWithKeychainPasscode()

        let done = expectation(description: "view")
        let disposable = (manager.accessChallengeData() |> take(1)).start(next: { view in
            XCTAssertEqual(view.data, Self.keychainPasscode)
            done.fulfill()
        })
        wait(for: [done], timeout: 10.0)
        disposable.dispose()
        _ = run(manager, { _ in })

        XCTAssertFalse(FileManager.default.fileExists(atPath: atomicStateURL.path))
        XCTAssertEqual(legacyAccessChallenge(), .none)
        XCTAssertTrue(appFirstLaunchSeesFreshInstallation())
    }

    func testExtensionResolvesTheAccessChallengeWithoutMigration() {
        var migrationRequests: [Bool] = []
        let manager = openAsExtension(resolve: { current, allowMigration in
            migrationRequests.append(allowMigration)
            return current
        })
        _ = run(manager, { $0.getAccessChallengeData() })

        XCTAssertFalse(migrationRequests.isEmpty)
        XCTAssertFalse(migrationRequests.contains(true), "an in-memory extension session must not migrate a legacy passcode")
    }

    func testExtensionTransactionsDoNotWriteTheInMemoryState() {
        let manager = openAsExtension(resolve: { _, _ in Self.keychainPasscode })
        run(manager, { transaction in
            _ = transaction.createRecord([])
            transaction.setVersion(7)
            transaction.setAccessChallengeData(Self.keychainPasscode)
        })

        XCTAssertFalse(FileManager.default.fileExists(atPath: atomicStateURL.path))
        XCTAssertEqual(withLegacyTables { _, metadata in metadata.getVersion() }, 0, "getVersion() reads an unset version as 0")
        XCTAssertEqual(legacyAccessChallenge(), .none)
        XCTAssertTrue(appFirstLaunchSeesFreshInstallation())
    }

    func testExtensionWithTheAppsStateStillWritesIt() throws {
        // Not the in-memory fallback: the app's own state, which an extension updates as before.
        let record = AccountRecordId(rawValue: 1)
        try JSONEncoder().encode(AccountManagerAtomicState<Types>(records: [record: AccountRecord<Types.Attribute>(id: record, attributes: [], temporarySessionId: nil)], currentRecordId: record)).write(to: atomicStateURL)

        let manager = openAsExtensionWithKeychainPasscode()
        _ = run(manager, { $0.getAccessChallengeData() })

        let state = try JSONDecoder().decode(AccountManagerAtomicState<Types>.self, from: Data(contentsOf: atomicStateURL))
        XCTAssertEqual(state.accessChallengeData, Self.keychainPasscode)
        XCTAssertEqual(legacyAccessChallenge(), Self.keychainPasscode)
    }

    func testAppStillPersistsAnAccessChallengeResolvedFromTheKeychain() throws {
        let app = open(removeDatabaseOnError: true, isTemporary: false, resolve: { _, _ in Self.keychainPasscode })
        XCTAssertEqual(run(app, { $0.getAccessChallengeData() }), Self.keychainPasscode)

        let state = try JSONDecoder().decode(AccountManagerAtomicState<Types>.self, from: Data(contentsOf: atomicStateURL))
        XCTAssertEqual(state.accessChallengeData, Self.keychainPasscode)
        XCTAssertEqual(legacyAccessChallenge(), Self.keychainPasscode)
    }

    // MARK: - Finding 2: only a missing atomic state falls back to the legacy tables

    private static let legacyRecord = AccountRecordId(rawValue: 1)
    private static let appRecord = AccountRecordId(rawValue: 2)
    private static let legacyPasscode: PostboxAccessChallengeData = .numericalPassword(value: "1234")

    /// The legacy tables an app updated from an old version still has: one account and a passcode.
    private func seedLegacyTables() {
        withLegacyTables { records, metadata in
            var recordOperations: [AccountManagerRecordOperation<Types.Attribute>] = []
            var metadataOperations: [AccountManagerMetadataOperation<Types.Attribute>] = []
            records.setRecord(id: Self.legacyRecord, record: AccountRecord<Types.Attribute>(id: Self.legacyRecord, attributes: [], temporarySessionId: nil), operations: &recordOperations)
            metadata.setCurrentAccountId(Self.legacyRecord, operations: &metadataOperations)
            metadata.setAccessChallengeData(Self.legacyPasscode)
        }
    }

    /// The app's own state: a different account than the stale legacy one.
    private func writeAppState() throws -> Data {
        let state = AccountManagerAtomicState<Types>(records: [Self.appRecord: AccountRecord<Types.Attribute>(id: Self.appRecord, attributes: [], temporarySessionId: nil)], currentRecordId: Self.appRecord, accessChallengeData: Self.legacyPasscode)
        let data = try JSONEncoder().encode(state)
        try data.write(to: atomicStateURL)
        return data
    }

    private func makeAtomicStateUnreadable() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: atomicStateURL.path)
        XCTAssertThrowsError(try Data(contentsOf: atomicStateURL), "the test needs a file that exists but cannot be read")
    }

    private func atomicStateBytes() throws -> Data {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: atomicStateURL.path)
        return try Data(contentsOf: atomicStateURL)
    }

    func testExtensionWithoutAtomicStateUsesTheLegacyRecords() {
        seedLegacyTables()

        let manager = openAsExtension()
        let view = manager._internalAccountRecordsSync()
        XCTAssertEqual(view.records.map(\.id), [Self.legacyRecord])
        XCTAssertEqual(view.currentRecord?.id, Self.legacyRecord)
        XCTAssertEqual(run(manager, { $0.getAccessChallengeData() }), Self.legacyPasscode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: atomicStateURL.path))
    }

    func testExtensionWithUnreadableAtomicStateOpensWithNoAccountsAndNeverWritesIt() throws {
        seedLegacyTables()
        let original = try writeAppState()
        try makeAtomicStateUnreadable()

        let manager = openAsExtension()
        let view = manager._internalAccountRecordsSync()
        XCTAssertTrue(view.records.isEmpty, "the stale legacy records are not the app's accounts")
        XCTAssertNil(view.currentRecord)
        XCTAssertEqual(run(manager, { $0.getAccessChallengeData() }), Self.legacyPasscode, "the extension still locks")
        run(manager, { transaction in
            _ = transaction.createRecord([])
        })

        XCTAssertEqual(try atomicStateBytes(), original, "an extension must not overwrite the app's state")
    }

    func testExtensionWithUndecodableAtomicStateOpensWithNoAccounts() throws {
        seedLegacyTables()
        let garbage = Data("not json".utf8)
        try garbage.write(to: atomicStateURL)

        let manager = openAsExtension()
        let view = manager._internalAccountRecordsSync()
        XCTAssertTrue(view.records.isEmpty, "the stale legacy records are not the app's accounts")
        XCTAssertNil(view.currentRecord)
        run(manager, { transaction in
            _ = transaction.createRecord([])
        })
        XCTAssertEqual(try Data(contentsOf: atomicStateURL), garbage)
    }

    func testAppWithUnreadableAtomicStateKeepsTheUpstreamRebuild() throws {
        seedLegacyTables()
        _ = try writeAppState()
        try makeAtomicStateUnreadable()

        let view = open(removeDatabaseOnError: true, isTemporary: false)._internalAccountRecordsSync()
        XCTAssertEqual(view.records.map(\.id), [Self.legacyRecord], "upstream: the app rebuilds the state from the legacy tables")
        // An atomic write keeps the replaced file's 0000 mode, so read it the way the test can.
        let rebuilt = try JSONDecoder().decode(AccountManagerAtomicState<Types>.self, from: atomicStateBytes())
        XCTAssertEqual(Array(rebuilt.records.keys), [Self.legacyRecord])
    }
}
