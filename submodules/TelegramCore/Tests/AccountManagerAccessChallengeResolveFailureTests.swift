import Foundation
import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

/// The Notification Service opens the account manager on every push, mostly while the device is locked: the passcode
/// credential is `WhenUnlockedThisDeviceOnly`, so the open-time resolve throws (errSecInteractionNotAllowed). The catch
/// dropped the error and logged "credential migration deferred" on about 92% of NSE launches, although the open-time
/// resolve of an extension (`isTemporary`) never migrates. The line now names the error and says a migration was
/// deferred only where the open-time resolve may migrate. An extension whose state is the app's file can still migrate
/// later, in a transaction's `getAccessChallengeData` (resolve with migration allowed); the tests pin that sequence.
/// The lock itself must not change: a resolve that throws keeps the stored passcode (fail closed).
final class AccountManagerAccessChallengeResolveFailureTests: XCTestCase {
    private typealias Types = TelegramAccountManagerTypes

    /// Stands in for PasscodeCore's `PasscodeError` (TelegramCore does not link it): same shape, same description.
    private enum FakePasscodeError: Error {
        case unavailable
        case keychain(Int32)
    }

    private static let errSecInteractionNotAllowedStatus: Int32 = -25308
    private static let storedPasscode: PostboxAccessChallengeData = .secured(id: "stored", kind: .digits6)

    /// XCTest makes one instance per test method, so each test has its own directory.
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-manager-access-challenge-resolve-failure-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // No tearDown removal, see AccountManagerExtensionReadOnlyTests.

    // MARK: - Log lines

    func testExtensionLineNamesTheErrorAndDoesNotClaimADeferredMigration() {
        let line = accessChallengeResolveFailedLogLine(error: FakePasscodeError.keychain(Self.errSecInteractionNotAllowedStatus), allowMigration: false)

        XCTAssertTrue(line.contains("keychain(-25308)"), line)
        XCTAssertTrue(line.contains("not resolved at open"), line)
        XCTAssertFalse(line.contains("migration deferred"), "the open-time resolve of an extension does not migrate: \(line)")
    }

    func testAppLineSaysTheMigrationIsDeferredAndNamesTheError() {
        let line = accessChallengeResolveFailedLogLine(error: FakePasscodeError.unavailable, allowMigration: true)

        XCTAssertTrue(line.contains("credential migration deferred"), line)
        XCTAssertTrue(line.contains("unavailable"), line)
    }

    func testPrepareLineNamesTheError() {
        let line = accessChallengePrepareFailedLogLine(error: FakePasscodeError.keychain(Self.errSecInteractionNotAllowedStatus))

        XCTAssertTrue(line.contains("Access challenge installation initialization deferred"), line)
        XCTAssertTrue(line.contains("keychain(-25308)"), line)
    }

    // MARK: - The lock is unchanged when resolve throws

    private func open(isTemporary: Bool, removeDatabaseOnError: Bool, migrationRequests: @escaping (Bool) -> Void, finishInitialization: @escaping () -> Void) -> AccountManager<Types> {
        return AccountManager<Types>(basePath: directory.path, isTemporary: isTemporary, isReadOnly: false, useCaches: false, removeDatabaseOnError: removeDatabaseOnError, accessChallenge: AccountManagerAccessChallenge(prepare: { _ in
        }, resolve: { _, allowMigration in
            migrationRequests(allowMigration)
            throw FakePasscodeError.keychain(Self.errSecInteractionNotAllowedStatus)
        }, finishInitialization: {
            finishInitialization()
        }))
    }

    private func run<T>(_ manager: AccountManager<Types>, _ f: @escaping (AccountManagerModifier<Types>) -> T) -> T? {
        let done = expectation(description: "transaction")
        var result: T?
        let disposable = (manager.transaction(f) |> take(1)).start(next: { value in
            result = value
            done.fulfill()
        })
        wait(for: [done], timeout: 10.0)
        disposable.dispose()
        return result
    }

    private func writeAppStateWithStoredPasscode() throws {
        let state = AccountManagerAtomicState<Types>(accessChallengeData: Self.storedPasscode)
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("atomic-state"))
    }

    func testExtensionKeepsTheStoredPasscodeWhenResolveThrows() throws {
        // The app's own state, as on a device where the app has run: not the in-memory fallback.
        try writeAppStateWithStoredPasscode()

        var migrationRequests: [Bool] = []
        var finishInitializationCalls = 0
        let manager = open(isTemporary: true, removeDatabaseOnError: false, migrationRequests: { migrationRequests.append($0) }, finishInitialization: { finishInitializationCalls += 1 })

        XCTAssertEqual(run(manager, { $0.getAccessChallengeData() }), Self.storedPasscode, "a resolve that throws must keep the lock")
        // Open: resolve without migration. Transaction: getAccessChallengeData resolves with migration allowed,
        // because the state is the app's file and not the in-memory fallback.
        XCTAssertEqual(migrationRequests, [false, true], "the open-time resolve of an extension does not migrate; the transaction-time one may")
        XCTAssertEqual(finishInitializationCalls, 0, "an extension never finishes the passcode initialization")
    }

    func testAppKeepsTheStoredPasscodeAndDefersFinishingWhenResolveThrows() throws {
        try writeAppStateWithStoredPasscode()

        var migrationRequests: [Bool] = []
        var finishInitializationCalls = 0
        let manager = open(isTemporary: false, removeDatabaseOnError: true, migrationRequests: { migrationRequests.append($0) }, finishInitialization: { finishInitializationCalls += 1 })

        XCTAssertEqual(run(manager, { $0.getAccessChallengeData() }), Self.storedPasscode, "a resolve that throws must keep the lock")
        XCTAssertEqual(migrationRequests, [true, true], "the app's open-time and transaction-time resolves may migrate")
        XCTAssertEqual(finishInitializationCalls, 0, "finishing waits for a resolve that succeeds")
    }
}
