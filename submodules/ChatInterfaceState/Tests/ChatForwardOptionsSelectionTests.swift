import XCTest
import SwiftSignalKit
import TelegramCore
@testable import ChatInterfaceState

/// The forward-options menu (`chatForwardOptions`) is rebuilt on every value of the selection count,
/// and every rebuild relays the context controller out with a 0.3 s spring
/// (`ContextControllerActionsStackNode.replace`). The preview chat publishes its whole interface
/// state on every update (`presentationInterfaceStatePromise`), most of which leave the selection alone.
final class ChatForwardOptionsSelectionTests: XCTestCase {
    private func messageId(_ id: Int32) -> EngineMessage.Id {
        return EngineMessage.Id(peerId: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(1)), namespace: Namespaces.Message.Cloud, id: id)
    }

    private func values(initialCount: Int, states: [ChatInterfaceState]) -> [Int] {
        var result: [Int] = []
        let disposable = chatForwardOptionsSelectedCount(initialCount: initialCount, previewInterfaceStates: Signal { subscriber in
            for state in states {
                subscriber.putNext(state)
            }
            return EmptyDisposable
        }).start(next: { value in
            result.append(value)
        })
        disposable.dispose()
        return result
    }

    func testUnchangedSelectionPublishesOnce() {
        let selected = ChatInterfaceState().withUpdatedSelectedMessages((1 ... 10).map(self.messageId))
        // The preview updates its state many times while it loads and scrolls; the selection stays.
        var states = Array(repeating: selected, count: 20)
        // Other state changes that keep the same selection.
        states.append(selected.withUpdatedSilentPosting(true))
        states.append(selected.withUpdatedInputLanguage("en"))
        XCTAssertEqual(self.values(initialCount: 10, states: states), [10])
    }

    func testSelectionChangesArePublished() {
        let all = (1 ... 10).map(self.messageId)
        let selected = ChatInterfaceState().withUpdatedSelectedMessages(all)
        let fewer = ChatInterfaceState().withUpdatedSelectedMessages(Array(all.prefix(7)))
        XCTAssertEqual(self.values(initialCount: 10, states: [selected, selected, fewer, fewer, selected]), [10, 7, 10])
    }

    func testNoSelectionCountsAsOne() {
        XCTAssertEqual(self.values(initialCount: 1, states: [ChatInterfaceState(), ChatInterfaceState()]), [1])
    }
}
