import Foundation
import XCTest
@testable import Postbox

/// A background-task drain that times out logs the transaction it was still waiting for: iOS kills an app that is
/// suspended while a transaction holds the SQLite lock (0xdead10cc), and that line is the only trace of which one.
final class PostboxRunningTransactionTests: XCTestCase {
    /// Readable from another thread while the transaction runs (the Postbox queue is busy then), and gone once it
    /// committed.
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

    func testDescriptionGivesTheSiteAndHowLongItHasRun() {
        let running = PostboxRunningTransaction(file: "/a/b/ChatListViewState.swift", line: 1078, startTime: 100.0)
        XCTAssertEqual(running.site, "ChatListViewState.swift:1078")
        XCTAssertEqual(running.logDescription(now: 104.3), "ChatListViewState.swift:1078 for 4300 ms")
        // A clock that went backwards does not give a negative age.
        XCTAssertEqual(running.logDescription(now: 99.0), "ChatListViewState.swift:1078 for 0 ms")
    }
}
