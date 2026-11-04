import Foundation
import XCTest
@testable import TelegramCore

/// `AccountManager.getCurrentRecords(basePath:)` is what the Intents extension's widget handler
/// (`WidgetIntentHandler.init`) reads the account list with. It ran `preconditionFailure()` when
/// `<basePath>/atomic-state` was missing or unreadable, which crashed the extension (Nanogram 13.1.1
/// (202611020509), MetricKit SIGTRAP in `AccountManagerImpl.getCurrentRecords`). Such state now reads
/// as no accounts.
final class AccountManagerCurrentRecordsTests: XCTestCase {
    private typealias Types = TelegramAccountManagerTypes

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-manager-current-records-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testMissingMetadataDirectoryReadsAsNoAccounts() {
        // The app has never opened its account manager: there is no accounts-metadata directory.
        let view = AccountManager<Types>.getCurrentRecords(basePath: directory.appendingPathComponent("accounts-metadata").path)
        XCTAssertTrue(view.records.isEmpty)
        XCTAssertNil(view.currentId)
    }

    func testMissingAtomicStateReadsAsNoAccounts() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = AccountManager<Types>.getCurrentRecords(basePath: directory.path)
        XCTAssertTrue(view.records.isEmpty)
        XCTAssertNil(view.currentId)
    }

    func testUndecodableAtomicStateReadsAsNoAccounts() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("atomic-state"))
        let view = AccountManager<Types>.getCurrentRecords(basePath: directory.path)
        XCTAssertTrue(view.records.isEmpty)
        XCTAssertNil(view.currentId)
    }

    func testValidAtomicStateReturnsRecordsInIdOrderAndCurrentRecord() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = AccountRecordId(rawValue: 1)
        let second = AccountRecordId(rawValue: 2)
        let state = AccountManagerAtomicState<Types>(records: [
            second: AccountRecord<Types.Attribute>(id: second, attributes: [], temporarySessionId: nil),
            first: AccountRecord<Types.Attribute>(id: first, attributes: [], temporarySessionId: nil)
        ], currentRecordId: second)
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("atomic-state"))

        let view = AccountManager<Types>.getCurrentRecords(basePath: directory.path)
        XCTAssertEqual(view.records.map(\.id), [first, second])
        XCTAssertEqual(view.currentId, second)
    }
}
