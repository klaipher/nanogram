import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

final class PeerStoriesSynchronizationRunnerTests: XCTestCase {
    private func peer(_ id: Int64) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(id))
    }

    func testRepeatedViewUpdatesForAPendingPeerStartOneRequest() {
        let runner = PeerStoriesSynchronizationRunner<Int>()
        var started: [Int] = []
        for _ in 0 ..< 5 {
            started += runner.update([(peer(1), 1)]).beginOperations.map { $0.0 }
        }
        XCTAssertEqual(started, [1])
    }

    func testANewQueuedPeerStartsOnlyItsOwnRequest() {
        let runner = PeerStoriesSynchronizationRunner<Int>()
        let first = runner.update((1 ... 10).map { (peer(Int64($0)), $0) })
        XCTAssertEqual(first.beginOperations.map { $0.0 }, Array(1 ... 10))

        let afterOneCompleted = runner.update((2 ... 11).map { (peer(Int64($0)), $0) })
        XCTAssertEqual(afterOneCompleted.beginOperations.map { $0.0 }, [11])
        XCTAssertEqual(afterOneCompleted.disposeOperations.count, 1)
    }

    func testARunningRequestIsNotReplacedOrOrphaned() {
        let runner = PeerStoriesSynchronizationRunner<Int>()
        let first = runner.update([(peer(1), 1)])
        let running = first.beginOperations[0].1
        var disposed = false
        running.set(ActionDisposable { disposed = true })

        let _ = runner.update([(peer(1), 1), (peer(2), 2)])
        XCTAssertFalse(disposed)

        let removed = runner.update([(peer(2), 2)])
        removed.disposeOperations.forEach { $0.dispose() }
        XCTAssertTrue(disposed)
    }
}
