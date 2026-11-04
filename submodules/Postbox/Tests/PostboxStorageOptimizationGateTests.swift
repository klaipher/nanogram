import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// The nightly cleanup task asks Postbox to VACUUM through `optimizeStorageIfNeeded`. It used to run straight on
/// the Postbox queue, so pausing transactions (the app is about to be suspended) queued behind a running VACUUM and
/// the app could be suspended with the file locked. It now goes through the same gate as transactions.
final class PostboxStorageOptimizationGateTests: XCTestCase {
    private var fixture: PostboxFixture!

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "PostboxStorageOptimizationGateTests")
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    private func setCanBeginTransactions(_ value: Bool) {
        let paused = DispatchSemaphore(value: 0)
        self.fixture.postbox.setCanBeginTransactions(value, afterTransactionIfRunning: {
            paused.signal()
        })
        XCTAssertEqual(paused.wait(timeout: .now() + 10.0), .success)
    }

    func testCheckWaitsWhileTransactionsArePausedAndRunsWhenTheyAreEnabled() {
        self.setCanBeginTransactions(false)

        let delivered = DispatchSemaphore(value: 0)
        let disposable = self.fixture.postbox.optimizeStorageIfNeeded().start(completed: {
            delivered.signal()
        })
        XCTAssertEqual(delivered.wait(timeout: .now() + 0.4), .timedOut, "a paused database must not start maintenance")

        self.setCanBeginTransactions(true)
        XCTAssertEqual(delivered.wait(timeout: .now() + 10.0), .success, "the queued check runs once transactions are enabled")
        disposable.dispose()
    }

    func testDisposedCheckNeverRuns() {
        self.setCanBeginTransactions(false)

        let ran = Atomic<Bool>(value: false)
        let disposable = self.fixture.postbox.optimizeStorageIfNeeded(shouldProceed: {
            let _ = ran.swap(true)
            return true
        }).start(completed: {
        })
        disposable.dispose()
        self.setCanBeginTransactions(true)

        // A round trip through the Postbox queue: the queued closure has run (and was cancelled) by now.
        XCTAssertNotNil(self.fixture.transaction({ _ in 0 }))
        XCTAssertFalse(ran.with { $0 })
    }

    func testInterruptingWithoutMaintenanceDoesNothing() {
        self.fixture.postbox.interruptMaintenance()
        XCTAssertNotNil(self.fixture.transaction({ _ in 0 }), "ordinary transactions are not affected")
    }
}
