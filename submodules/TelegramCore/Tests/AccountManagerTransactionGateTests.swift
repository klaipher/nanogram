import Foundation
import XCTest
import SwiftSignalKit
import Postbox
@testable import TelegramCore

/// The accounts-metadata database is in the shared app group container, like the Postbox ones, but had no gate:
/// a commit in flight when iOS suspended the app could leave the file locked (0xdead10cc). Transactions now wait
/// while the gate is closed, run when it opens, and urgent ones (`ignoreDisabled`) still run at once.
final class AccountManagerTransactionGateTests: XCTestCase {
    private typealias Types = TelegramAccountManagerTypes

    private var directory: URL!
    private var manager: AccountManager<Types>!

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-manager-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.manager = AccountManager<Types>(basePath: self.directory.path, isTemporary: true, isReadOnly: false, useCaches: false, removeDatabaseOnError: true, accessChallenge: AccountManagerAccessChallenge(prepare: { _ in
        }, resolve: { current, _ in
            return current
        }, finishInitialization: {
        }))
    }

    private func setGate(_ value: Bool) {
        let done = DispatchSemaphore(value: 0)
        self.manager.setCanBeginTransactions(value, afterTransactionIfRunning: {
            done.signal()
        })
        XCTAssertEqual(done.wait(timeout: .now() + 10.0), .success)
    }

    func testTransactionWaitsWhileTheGateIsClosedAndRunsWhenItOpens() {
        self.setGate(false)

        let ran = DispatchSemaphore(value: 0)
        let disposable = self.manager.transaction({ _ in 1 }).start(next: { _ in
            ran.signal()
        })
        XCTAssertEqual(ran.wait(timeout: .now() + 0.4), .timedOut, "no transaction may begin while the gate is closed")

        self.setGate(true)
        XCTAssertEqual(ran.wait(timeout: .now() + 10.0), .success, "the queued transaction runs when the gate opens")
        disposable.dispose()
    }

    func testUrgentTransactionIgnoresTheGate() {
        self.setGate(false)

        let ran = DispatchSemaphore(value: 0)
        let disposable = self.manager.transaction(ignoreDisabled: true, { _ in 1 }).start(next: { _ in
            ran.signal()
        })
        XCTAssertEqual(ran.wait(timeout: .now() + 10.0), .success)
        disposable.dispose()
        self.setGate(true)
    }

    func testCallbackRunsAfterTheRunningTransaction() {
        let order = Atomic<[String]>(value: [])
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let disposable = self.manager.transaction({ _ -> Int in
            started.signal()
            Thread.sleep(forTimeInterval: 0.2)
            let _ = order.modify { $0 + ["transaction"] }
            return 1
        }).start(next: { _ in
        })
        XCTAssertEqual(started.wait(timeout: .now() + 10.0), .success)
        self.manager.setCanBeginTransactions(false, afterTransactionIfRunning: {
            let _ = order.modify { $0 + ["paused"] }
            finished.signal()
        })
        XCTAssertEqual(finished.wait(timeout: .now() + 10.0), .success)
        XCTAssertEqual(order.with { $0 }, ["transaction", "paused"])
        disposable.dispose()
        self.setGate(true)
    }

    func testViewsAreNotHeldBackByTheGate() {
        self.setGate(false)
        let got = DispatchSemaphore(value: 0)
        let disposable = self.manager.accountRecords().start(next: { _ in
            got.signal()
        })
        XCTAssertEqual(got.wait(timeout: .now() + 10.0), .success, "reading the account list at launch must not wait")
        disposable.dispose()
        self.setGate(true)
    }
}
