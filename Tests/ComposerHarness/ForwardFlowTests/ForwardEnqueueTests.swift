import XCTest
import QuartzCore
import SwiftSignalKit
import Postbox
import TelegramCore
@testable import HarnessAppContext

/// Forwards enqueued through the public `enqueueMessages(account:peerId:messages:)`, the call every
/// forward entry point (chat Send with a forward panel, the picker, the share sheet) ends in, against
/// a real account's Postbox.
final class ForwardEnqueueTests: XCTestCase {
    private static var fixture: ForwardFlowFixture?
    private static var nextMessageId: Int32 = 100_000

    private var fixture: ForwardFlowFixture {
        if let fixture = ForwardEnqueueTests.fixture {
            return fixture
        }
        let fixture = ForwardFlowFixture(testCase: self)
        ForwardEnqueueTests.fixture = fixture
        return fixture
    }

    private func storeSources(count: Int, authorCount: Int) -> [MessageId] {
        let first = ForwardEnqueueTests.nextMessageId
        ForwardEnqueueTests.nextMessageId += Int32(count)
        return self.fixture.storeSourceMessages(count: count, authorCount: authorCount, firstId: first, attributesForIndex: { index in
            if index % 3 == 0 {
                return [TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< 7, type: .Bold)])]
            }
            return []
        })
    }

    private func forwards(_ ids: [MessageId], hideNames: Bool, hideCaptions: Bool) -> [EnqueueMessage] {
        let attributes: [MessageAttribute] = [ForwardOptionsMessageAttribute(hideNames: hideNames, hideCaptions: hideCaptions)]
        return ids.map { .forward(source: $0, threadId: nil, grouping: .auto, attributes: attributes, correlationId: nil) }
    }

    private func enqueue(_ messages: [EnqueueMessage], to peerId: PeerId) -> [MessageId?] {
        return ForwardFlowFixture.wait(enqueueMessages(account: self.fixture.account, peerId: peerId, messages: messages))
    }

    /// Everything about a stored forward that does not vary from run to run (random ids, the send
    /// flags the pending-message manager changes, local ids).
    private func describe(_ message: Message, sources: [MessageId]) -> String {
        var parts: [String] = []
        parts.append("peer=\(message.id.peerId.id._internalGetInt64Value())")
        parts.append("ns=\(message.id.namespace)")
        parts.append("text=\(message.text)")
        parts.append("author=\(message.author?.id.id._internalGetInt64Value() ?? 0)")
        if let forwardInfo = message.forwardInfo {
            parts.append("fwd(author=\(forwardInfo.author?.id.id._internalGetInt64Value() ?? 0) source=\(forwardInfo.source?.id.id._internalGetInt64Value() ?? 0) date=\(forwardInfo.date))")
        } else {
            parts.append("fwd=nil")
        }
        parts.append("grouping=\(message.groupingKey != nil)")
        parts.append("tags=\(message.tags.rawValue)")
        for attribute in message.attributes {
            if let attribute = attribute as? ForwardSourceInfoAttribute {
                parts.append("source=\(sources.firstIndex(of: attribute.messageId).map(String.init) ?? "?")")
            } else if let attribute = attribute as? ForwardOptionsMessageAttribute {
                parts.append("options(\(attribute.hideNames),\(attribute.hideCaptions))")
            } else if let attribute = attribute as? TextEntitiesMessageAttribute {
                parts.append("entities=\(attribute.entities.count)")
            } else if attribute is OutgoingMessageInfoAttribute {
                parts.append("outgoingInfo")
            } else {
                parts.append("\(type(of: attribute))")
            }
        }
        return parts.joined(separator: " ")
    }

    func testHundredForwardsStoreTheSameMessages() {
        let sources = self.storeSources(count: 100, authorCount: 7)
        let ids = self.enqueue(self.forwards(sources, hideNames: false, hideCaptions: false), to: ForwardFlowFixture.destinationUserId)
        XCTAssertEqual(ids.count, 100)
        XCTAssertEqual(ids.compactMap { $0 }.count, 100)
        let stored = self.fixture.messages(ids.compactMap { $0 })
        XCTAssertEqual(stored.count, 100)
        let descriptions = stored.map { self.describe($0, sources: sources) }
        for (index, description) in descriptions.enumerated() {
            let author = 7000 + index % 7
            let date = 1_700_000_000 + index
            let entities = index % 3 == 0 ? " entities=1" : ""
            XCTAssertEqual(description, "peer=6001 ns=\(Namespaces.Message.Local) text=Message \(index) author=\(HarnessAccount.harnessPeerId.id._internalGetInt64Value()) fwd(author=\(author) source=0 date=\(date)) grouping=false tags=0 outgoingInfo source=\(index) options(false,false)\(entities)", "message \(index)")
        }
        XCTAssertEqual(stored.map(\.timestamp), stored.map(\.timestamp).sorted(), "forwards are stored out of order")
    }

    func testHiddenNamesAreStoredWithoutForwardInfo() {
        let sources = self.storeSources(count: 10, authorCount: 3)
        let ids = self.enqueue(self.forwards(sources, hideNames: true, hideCaptions: true), to: ForwardFlowFixture.destinationUserId)
        let stored = self.fixture.messages(ids.compactMap { $0 })
        XCTAssertEqual(stored.count, 10)
        for (index, message) in stored.enumerated() {
            let entities = index % 3 == 0 ? " entities=1" : ""
            XCTAssertEqual(self.describe(message, sources: sources), "peer=6001 ns=\(Namespaces.Message.Local) text=Message \(index) author=\(HarnessAccount.harnessPeerId.id._internalGetInt64Value()) fwd=nil grouping=false tags=0 outgoingInfo source=\(index) options(true,true)\(entities)", "message \(index)")
        }
    }

    /// Prints the cost of enqueueing N forwards into one chat, measured from the call to the ids
    /// coming back. Not an assertion: the numbers go into the commit message.
    func testBenchmarkEnqueue() {
        var lines: [String] = []
        for count in [1, 10, 100] {
            var samples: [Double] = []
            for _ in 0 ..< 6 {
                let sources = self.storeSources(count: count, authorCount: 5)
                let messages = self.forwards(sources, hideNames: false, hideCaptions: false)
                let start = CACurrentMediaTime()
                let ids = self.enqueue(messages, to: ForwardFlowFixture.destinationUserId)
                samples.append(CACurrentMediaTime() - start)
                XCTAssertEqual(ids.compactMap { $0 }.count, count)
            }
            samples.removeFirst()
            lines.append("forwards=\(count) enqueue=\(String(format: "%.2f", samples.min()! * 1000.0)) ms (median \(String(format: "%.2f", samples.sorted()[samples.count / 2] * 1000.0)) ms)")
        }
        print("FORWARD_ENQUEUE_BENCH\n" + lines.joined(separator: "\n"))
    }
}
