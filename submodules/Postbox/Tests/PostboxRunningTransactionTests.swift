import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// A background-task drain that times out logs the transaction it was still waiting for: iOS kills an app that is
/// suspended while a transaction holds the SQLite lock (0xdead10cc), and that line is the only trace of which one.
final class PostboxRunningTransactionTests: XCTestCase {
    /// Set while the transaction runs (read here from inside it, on the Postbox queue), and gone once it committed.
    func testTheRunningTransactionIsVisibleOnlyWhileItRuns() {
        let fixture = PostboxFixture(name: "PostboxRunningTransactionTests")
        defer {
            fixture.close()
        }
        let postbox: Postbox = fixture.postbox
        XCTAssertNil(postbox.runningTransaction())
        let seen = fixture.transaction { _ -> PostboxRunningTransaction? in
            return postbox.runningTransaction()
        }
        let running = seen.flatMap { $0 }
        XCTAssertNotNil(running)
        // The fixture's `transaction` helper opens it, so that is the call site Postbox records.
        XCTAssertEqual(running.map { $0.site.hasPrefix("PostboxFixture.swift:") }, true)
        XCTAssertNil(postbox.runningTransaction())
    }

    /// The drain-timeout line reads it on the main queue while the Postbox queue is busy with the transaction: the
    /// read must not wait for that queue. The transaction here blocks the queue until the read is done.
    func testReadableFromAnotherThreadWhileTheQueueIsBusy() {
        let fixture = PostboxFixture(name: "PostboxRunningTransactionCrossThreadTests")
        defer {
            fixture.close()
        }
        let postbox: Postbox = fixture.postbox
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let disposable = postbox.transaction({ _ -> Void in
            started.signal()
            let _ = proceed.wait(timeout: .now() + 10.0)
        }).start(completed: {
            finished.signal()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 10.0), .success)
        XCTAssertFalse(fixture.queue.isCurrent())
        let running = postbox.runningTransaction()
        proceed.signal()
        XCTAssertEqual(running.map { $0.site.hasPrefix("PostboxRunningTransactionTests.swift:") }, true)
        XCTAssertEqual(finished.wait(timeout: .now() + 10.0), .success)
        disposable.dispose()
        XCTAssertNil(postbox.runningTransaction())
    }

    func testDescriptionGivesTheSiteAndHowLongItHasRun() {
        let running = PostboxRunningTransaction(file: "/a/b/ChatListViewState.swift", line: 1078, startTime: 100.0)
        XCTAssertEqual(running.site, "ChatListViewState.swift:1078")
        XCTAssertEqual(running.logDescription(now: 104.3), "ChatListViewState.swift:1078 for 4300 ms")
        // A clock that went backwards does not give a negative age.
        XCTAssertEqual(running.logDescription(now: 99.0), "ChatListViewState.swift:1078 for 0 ms")
    }
}
