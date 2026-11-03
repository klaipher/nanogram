import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

final class PeerStoriesSynchronizationRunner<Entry> {
    private var operationDisposables: [PeerId: MetaDisposable] = [:]
    
    func update(_ entries: [(peerId: PeerId, entry: Entry)]) -> (disposeOperations: [Disposable], beginOperations: [(Entry, MetaDisposable)]) {
        var disposeOperations: [Disposable] = []
        var beginOperations: [(Entry, MetaDisposable)] = []
        
        var validPeerIds: [PeerId] = []
        for (peerId, entry) in entries {
            validPeerIds.append(peerId)
            if self.operationDisposables[peerId] == nil {
                let disposable = MetaDisposable()
                self.operationDisposables[peerId] = disposable
                beginOperations.append((entry, disposable))
            }
        }
        
        var removedPeerIds: [PeerId] = []
        for (peerId, disposable) in self.operationDisposables {
            if !validPeerIds.contains(peerId) {
                removedPeerIds.append(peerId)
                disposeOperations.append(disposable)
            }
        }
        for peerId in removedPeerIds {
            self.operationDisposables.removeValue(forKey: peerId)
        }
        
        return (disposeOperations, beginOperations)
    }
    
    func reset() -> [Disposable] {
        let disposables = Array(self.operationDisposables.values)
        self.operationDisposables.removeAll()
        return disposables
    }
}

private final class ManagedSynchronizePeerStoriesOperationsHelper {
    private let runner = PeerStoriesSynchronizationRunner<PeerMergedOperationLogEntry>()
    
    func update(_ entries: [PeerMergedOperationLogEntry]) -> (disposeOperations: [Disposable], beginOperations: [(PeerMergedOperationLogEntry, MetaDisposable)]) {
        return self.runner.update(entries.compactMap { entry in
            guard entry.contents is SynchronizePeerStoriesOperation else {
                return nil
            }
            return (entry.peerId, entry)
        })
    }
    
    func reset() -> [Disposable] {
        return self.runner.reset()
    }
}

private func withTakenOperation(postbox: Postbox, peerId: PeerId, tagLocalIndex: Int32, _ f: @escaping (Transaction, PeerMergedOperationLogEntry?) -> Signal<Void, NoError>) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Signal<Void, NoError> in
        var result: PeerMergedOperationLogEntry?
        transaction.operationLogUpdateEntry(peerId: peerId, tag: OperationLogTags.SynchronizePeerStories, tagLocalIndex: tagLocalIndex, { entry in
            if let entry = entry, let _ = entry.mergedIndex, entry.contents is SynchronizePeerStoriesOperation  {
                result = entry.mergedEntry!
                return PeerOperationLogEntryUpdate(mergedIndex: .none, contents: .none)
            } else {
                return PeerOperationLogEntryUpdate(mergedIndex: .none, contents: .none)
            }
        })
        
        return f(transaction, result)
    } |> switchToLatest
}

func managedSynchronizePeerStoriesOperations(postbox: Postbox, network: Network, stateManager: AccountStateManager) -> Signal<Void, NoError> {
    return Signal { _ in
        let helper = Atomic<ManagedSynchronizePeerStoriesOperationsHelper>(value: ManagedSynchronizePeerStoriesOperationsHelper())
        
        let disposable = postbox.mergedOperationLogView(tag: OperationLogTags.SynchronizePeerStories, limit: 10).start(next: { view in
            let (disposeOperations, beginOperations) = helper.with { helper -> (disposeOperations: [Disposable], beginOperations: [(PeerMergedOperationLogEntry, MetaDisposable)]) in
                return helper.update(view.entries)
            }
            
            for disposable in disposeOperations {
                disposable.dispose()
            }
            
            for (entry, disposable) in beginOperations {
                let signal = withTakenOperation(postbox: postbox, peerId: entry.peerId, tagLocalIndex: entry.tagLocalIndex, { transaction, entry -> Signal<Void, NoError> in
                    if let entry = entry {
                        if let operation = entry.contents as? SynchronizePeerStoriesOperation {
                            if let peer = transaction.getPeer(entry.peerId) {
                                return pushStoriesAreSeen(postbox: postbox, network: network, stateManager: stateManager, peer: peer, operation: operation)
                            } else {
                                return .complete()
                            }
                        } else {
                            assertionFailure()
                        }
                    }
                    return .complete()
                })
                |> then(postbox.transaction { transaction -> Void in
                    let _ = transaction.operationLogRemoveEntry(peerId: entry.peerId, tag: OperationLogTags.SynchronizePeerStories, tagLocalIndex: entry.tagLocalIndex)
                })
                
                disposable.set(signal.start())
            }
        })
        
        return ActionDisposable {
            let disposables = helper.with { helper -> [Disposable] in
                return helper.reset()
            }
            for disposable in disposables {
                disposable.dispose()
            }
            disposable.dispose()
        }
    }
}

private func pushStoriesAreSeen(postbox: Postbox, network: Network, stateManager: AccountStateManager, peer: Peer, operation: SynchronizePeerStoriesOperation) -> Signal<Void, NoError> {
    return _internal_pollPeerStories(postbox: postbox, network: network, accountPeerId: stateManager.accountPeerId, peerId: peer.id, peerReference: PeerReference(peer))
    |> map { _ -> Void in
    }
}
