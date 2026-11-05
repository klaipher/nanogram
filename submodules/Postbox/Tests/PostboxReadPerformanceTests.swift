import Foundation
import XCTest
@testable import Postbox

/// Reading a chat's history from the message table: `fetch` of the newest 2500 of 10000 messages out of an in-memory
/// database, the read behind every chat open. Measures wall clock, CPU and peak memory.
///
/// Skipped unless TG_PERF=1, so the normal test runs stay fast and free of timing noise. Run with
/// `tools/dev/tg perf run postbox` (docs/profiling.md, "Tests that measure"); the numbers are compared with the
/// repository baselines by tools/dev/perfgate.py.
final class PostboxReadPerformanceTests: XCTestCase {
    private static let messageCount = 10000
    private static let readCount = 2500

    private var fixture: MessageHistoryTableFixture!
    private let peer = MessageHistoryTableFixture.peerId(900)
    private let namespace = MessageHistoryTableFixture.messageNamespace

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TG_PERF"] == "1", "performance tests run with TG_PERF=1 (tg perf run)")
        self.fixture = MessageHistoryTableFixture(name: "PostboxReadPerformanceTests")
        let text = String(repeating: "A line of an ordinary message with some words. ", count: 4)
        let messages = (1 ... Int32(PostboxReadPerformanceTests.messageCount)).map { id in
            return MessageHistoryTableFixture.storeMessage(id: MessageHistoryTableFixture.messageId(peer: 900, id: id), timestamp: 1_700_000_000 + id, text: text)
        }
        self.fixture.addMessages(messages)
    }

    override func tearDown() {
        self.fixture?.close()
        self.fixture = nil
        super.tearDown()
    }

    func testFetchNewestMessagesOfAChat() {
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        var fetched = 0
        self.measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            self.fixture.queue.sync {
                let messages = self.fixture.messageHistoryTable.fetch(
                    peerId: self.peer,
                    namespace: self.namespace,
                    tag: nil,
                    customTag: nil,
                    threadId: nil,
                    from: MessageIndex.upperBound(peerId: self.peer, namespace: self.namespace),
                    includeFrom: false,
                    to: MessageIndex.lowerBound(peerId: self.peer, namespace: self.namespace),
                    ignoreMessagesInTimestampRange: nil,
                    ignoreMessageIds: Set(),
                    limit: PostboxReadPerformanceTests.readCount
                )
                fetched = messages.count
            }
        }
        XCTAssertEqual(fetched, PostboxReadPerformanceTests.readCount)
    }
}
