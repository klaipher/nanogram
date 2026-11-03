import Foundation
import XCTest
import Postbox
@testable import TelegramCore

/// The extensions (Siri, Share, Notification Service, Notification Content) open the account manager's SQLite databases
/// while the app may hold them, or before first unlock. `AccountManagerImpl.init` trapped when `guard_db` or `db` could
/// not be opened, which crashed the extension instead of letting it answer "open the app". `openForExtension` returns
/// nil instead; the app's own open keeps its crash-and-relaunch policy.
final class AccountManagerExtensionOpenFailureTests: XCTestCase {
    private typealias Types = TelegramAccountManagerTypes

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-manager-extension-open-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // No tearDown removal, see AccountManagerExtensionReadOnlyTests.

    private func openForExtension() -> AccountManager<Types>? {
        return AccountManager<Types>.openForExtension(basePath: directory.path, isTemporary: true, isReadOnly: false, useCaches: false, accessChallenge: AccountManagerAccessChallenge(prepare: { _ in
        }, resolve: { current, _ in
            return current
        }, finishInitialization: {
        }))
    }

    private func makeUnreadable(_ name: String) throws {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        self.addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func testOpensWhenTheDatabasesCanBeOpened() {
        let manager = self.openForExtension()
        XCTAssertNotNil(manager)
        XCTAssertEqual(manager?._internalAccountRecordsSync().records.count, 0)
    }

    func testNoManagerWhenTheGuardDatabaseCannotBeOpened() throws {
        try self.makeUnreadable("guard_db")
        XCTAssertNil(self.openForExtension())
    }

    func testNoManagerWhenTheDatabaseCannotBeOpened() throws {
        try self.makeUnreadable("db")
        XCTAssertNil(self.openForExtension())
    }
}
