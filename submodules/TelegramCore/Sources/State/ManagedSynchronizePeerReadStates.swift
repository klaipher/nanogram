import Foundation
import Postbox
import SwiftSignalKit

/// How long a peer's read-state operation waits before it runs again after its `attempt`-th failure in a row: 1 s, 2 s,
/// 4 s, ... up to 30 s. Upstream starts it again at once, which spins one `messages.getPeerDialogs` per round trip while
/// the server's read mark stays behind the local one (`localReadMarkIsAheadOfServer`).
func peerReadStateSyncRetryDelay(attempt: Int) -> Double {
    if attempt <= 1 {
        return 1.0
    }
    let exponent = min(attempt - 1, 5)
    return min(30.0, Double(1 << exponent))
}

private final class SynchronizePeerReadStatesContextImpl {
    private final class Operation {
        let operation: PeerReadStateSynchronizationOperation
        let disposable: Disposable
        
        init(
            operation: PeerReadStateSynchronizationOperation,
            disposable: Disposable
        ) {
            self.operation = operation
            self.disposable = disposable
        }
        
        deinit {
            self.disposable.dispose()
        }
    }
    
    /// A peer whose operation failed and waits for `peerReadStateSyncRetryDelay` before it runs again. Only an operation
    /// with the same payload waits: a new read mark or a different operation starts at once.
    private final class RetryWait {
        let payload: PeerReadStateSyncPayload
        let timer: Disposable
        
        init(payload: PeerReadStateSyncPayload, timer: Disposable) {
            self.payload = payload
            self.timer = timer
        }
        
        deinit {
            self.timer.dispose()
        }
    }
    
    private let queue: Queue
    private let network: Network
    private let postbox: Postbox
    private let stateManager: AccountStateManager
    private let retryDelay: (Int) -> Double
    
    private var disposable: Disposable?
    
    private var currentState: [PeerId : PeerReadStateSynchronizationOperation] = [:]
    private var activeOperations: [PeerId: Operation] = [:]
    private var pendingOperations: [PeerId: PeerReadStateSynchronizationOperation] = [:]
    private var failureCounts: [PeerId: Int] = [:]
    private var retryWaits: [PeerId: RetryWait] = [:]
    
    init(queue: Queue, network: Network, postbox: Postbox, stateManager: AccountStateManager, retryDelay: @escaping (Int) -> Double) {
        self.queue = queue
        self.network = network
        self.postbox = postbox
        self.stateManager = stateManager
        self.retryDelay = retryDelay
        
        self.disposable = (postbox.synchronizePeerReadStatesView()
        |> deliverOn(self.queue)).start(next: { [weak self] view in
            guard let strongSelf = self else {
                return
            }
            strongSelf.currentState = view.operations
            strongSelf.update()
        })
    }
    
    deinit {
        self.disposable?.dispose()
    }
    
    func dispose() {
    }
    
    private func update() {
        let peerIds = Set(self.currentState.keys).union(Set(self.pendingOperations.keys))
        
        for peerId in peerIds {
            var maybeOperation: PeerReadStateSynchronizationOperation?
            if let operation = self.currentState[peerId] {
                maybeOperation = operation
                Logger.shared.log("SynchronizePeerReadStates", "\(peerId): take new operation \(operation)")
            } else if let operation = self.pendingOperations[peerId] {
                maybeOperation = operation
                self.pendingOperations.removeValue(forKey: peerId)
                Logger.shared.log("SynchronizePeerReadStates", "\(peerId): retrieve pending operation \(operation)")
            }
            
            if let operation = maybeOperation {
                if self.activeOperations[peerId] == nil, let retryWait = self.retryWaits[peerId], retryWait.payload == operation.syncPayload {
                    if self.currentState[peerId] == nil {
                        // Taken from pendingOperations above: keep it for when the wait ends.
                        self.pendingOperations[peerId] = operation
                    }
                    continue
                }
                if let current = self.activeOperations[peerId] {
                    // Compared by what is sent: a Push carries the whole read state, and a change in the top known id, the
                    // outgoing read id or the unread count is not a different push.
                    if current.operation.syncPayload != operation.syncPayload {
                        Logger.shared.log("SynchronizePeerReadStates", "\(peerId): store pending operation \(operation) (active is \(current.operation))")
                        self.pendingOperations[peerId] = operation
                    } else {
                        Logger.shared.log("SynchronizePeerReadStates", "\(peerId): do nothing, no change in \(operation)")
                    }
                } else {
                    if self.retryWaits.removeValue(forKey: peerId) != nil {
                        Logger.shared.log("SynchronizePeerReadStates", "\(peerId): operation changed, retry wait cancelled")
                        self.failureCounts.removeValue(forKey: peerId)
                    }
                    Logger.shared.log("SynchronizePeerReadStates", "\(peerId): begin operation \(operation)")
                    let operationDisposable = MetaDisposable()
                    let activeOperation = Operation(
                        operation: operation,
                        disposable: operationDisposable
                    )
                    self.activeOperations[peerId] = activeOperation
                    let signal: Signal<Never, PeerReadStateValidationError>
                    switch operation {
                    case .Validate:
                        signal = synchronizePeerReadState(network: self.network, postbox: self.postbox, stateManager: self.stateManager, peerId: peerId, push: false, validate: true, ledger: self.stateManager.readStatePushLedger)
                        |> ignoreValues
                    case let .Push(_, thenSync):
                        signal = synchronizePeerReadState(network: self.network, postbox: self.postbox, stateManager: stateManager, peerId: peerId, push: true, validate: thenSync, ledger: self.stateManager.readStatePushLedger)
                        |> ignoreValues
                    }
                    operationDisposable.set((signal
                    |> deliverOn(self.queue)).start(error: { [weak self, weak activeOperation] _ in
                        guard let strongSelf = self else {
                            return
                        }
                        if let activeOperation = activeOperation {
                            if let current = strongSelf.activeOperations[peerId], current === activeOperation {
                                strongSelf.activeOperations.removeValue(forKey: peerId)
                                strongSelf.scheduleRetry(peerId: peerId, operation: operation)
                                strongSelf.update()
                            }
                        }
                    }, completed: { [weak self, weak activeOperation] in
                        guard let strongSelf = self else {
                            return
                        }
                        if let activeOperation = activeOperation {
                            if let current = strongSelf.activeOperations[peerId], current === activeOperation {
                                Logger.shared.log("SynchronizePeerReadStates", "\(peerId): operation completed \(operation)")
                                strongSelf.activeOperations.removeValue(forKey: peerId)
                                strongSelf.failureCounts.removeValue(forKey: peerId)
                                strongSelf.update()
                            }
                        }
                    }))
                }
            }
        }
    }
    
    /// A failed operation runs again after a growing delay instead of at once; `update()` holds the peer back until the
    /// wait ends, unless an operation with another payload comes in meanwhile.
    private func scheduleRetry(peerId: PeerId, operation: PeerReadStateSynchronizationOperation) {
        let attempt = (self.failureCounts[peerId] ?? 0) + 1
        self.failureCounts[peerId] = attempt
        let retryAfter = self.retryDelay(attempt)
        Logger.shared.log("SynchronizePeerReadStates", "\(peerId): operation retry \(operation) in \(retryAfter) s (attempt \(attempt))")
        
        let timer = MetaDisposable()
        let retryWait = RetryWait(payload: operation.syncPayload, timer: timer)
        self.retryWaits[peerId] = retryWait
        timer.set((Signal<Never, NoError>.complete()
        |> delay(retryAfter, queue: self.queue)).start(completed: { [weak self, weak retryWait] in
            guard let strongSelf = self, let retryWait = retryWait else {
                return
            }
            if let current = strongSelf.retryWaits[peerId], current === retryWait {
                strongSelf.retryWaits.removeValue(forKey: peerId)
                if strongSelf.currentState[peerId] == nil && strongSelf.pendingOperations[peerId] == nil && strongSelf.activeOperations[peerId] == nil {
                    // Confirmed meanwhile by another path: nothing left to retry.
                    strongSelf.failureCounts.removeValue(forKey: peerId)
                }
                strongSelf.update()
            }
        }))
    }
}

private final class SynchronizePeerReadStatesStatesContext {
    private let queue: Queue
    private let impl: QueueLocalObject<SynchronizePeerReadStatesContextImpl>
    
    init(network: Network, postbox: Postbox, stateManager: AccountStateManager, retryDelay: @escaping (Int) -> Double) {
        self.queue = Queue()
        let queue = self.queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return SynchronizePeerReadStatesContextImpl(queue: queue, network: network, postbox: postbox, stateManager: stateManager, retryDelay: retryDelay)
        })
    }
    
    func dispose() {
        self.impl.with { impl in
            impl.dispose()
        }
    }
}

/// `retryDelay` is how long a failed operation waits before it runs again, by its failures in a row; tests shorten it.
func managedSynchronizePeerReadStates(network: Network, postbox: Postbox, stateManager: AccountStateManager, retryDelay: @escaping (Int) -> Double = peerReadStateSyncRetryDelay(attempt:)) -> Signal<Void, NoError> {
    return Signal { _ in
        let context = SynchronizePeerReadStatesStatesContext(network: network, postbox: postbox, stateManager: stateManager, retryDelay: retryDelay)
        
        return ActionDisposable {
            context.dispose()
        }
    }
}
