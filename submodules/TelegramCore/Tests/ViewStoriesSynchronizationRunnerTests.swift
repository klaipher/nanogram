import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

// ManagedSynchronizeViewStoriesOperations queues one stories.readStories(maxId) per peer and runs the
// mergedOperationLogView window (10 entries) through PeerStoriesSynchronizationRunner, keyed by the read story id.
final class ViewStoriesSynchronizationRunnerTests: XCTestCase {
    private func peer(_ id: Int64) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(id))
    }

    func testRepeatedViewUpdatesForTheSameReadStoryStartOneRequest() {
        let runner = PeerStoriesSynchronizationRunner<Int>()
        var started: [Int] = []
        for _ in 0 ..< 5 {
            started += runner.update([(peerId: peer(1), storyId: Int32?(7), entry: 1)]).beginOperations.map { $0.0 }
        }
        XCTAssertEqual(started, [1])
    }

    func testANewQueuedPeerStartsOnlyItsOwnRequest() {
        let runner = PeerStoriesSynchronizationRunner<Int>()
        let first = runner.update((1 ... 10).map { (peerId: peer(Int64($0)), storyId: Int32?(100), entry: $0) })
        XCTAssertEqual(first.beginOperations.map { $0.0 }, Array(1 ... 10))

        let afterOneCompleted = runner.update((2 ... 11).map { (peerId: peer(Int64($0)), storyId: Int32?(100), entry: $0) })
        XCTAssertEqual(afterOneCompleted.beginOperations.map { $0.0 }, [11])
        XCTAssertEqual(afterOneCompleted.disposeOperations.count, 1)
    }

    func testANewerReadStoryReplacesTheRunningRequestOfThatPeerOnly() {
        let runner = PeerStoriesSynchronizationRunner<Int>()
        let first = runner.update([(peerId: peer(1), storyId: Int32?(7), entry: 1), (peerId: peer(2), storyId: Int32?(3), entry: 2)])
        var disposed: [Int] = []
        for (entry, disposable) in first.beginOperations {
            disposable.set(ActionDisposable { disposed.append(entry) })
        }

        let newer = runner.update([(peerId: peer(1), storyId: Int32?(8), entry: 3), (peerId: peer(2), storyId: Int32?(3), entry: 2)])
        XCTAssertEqual(newer.beginOperations.map { $0.0 }, [3])
        newer.disposeOperations.forEach { $0.dispose() }
        XCTAssertEqual(disposed, [1])
    }
}
