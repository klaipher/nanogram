import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

func _internal_removePeerChat(account: Account, peerId: PeerId, reportChatSpam: Bool, deleteGloballyIfPossible: Bool = false) -> Signal<Void, NoError> {
    return account.postbox.transaction { transaction -> Void in
        _internal_removePeerChat(account: account, transaction: transaction, mediaBox: account.postbox.mediaBox, peerId: peerId, reportChatSpam: reportChatSpam, deleteGloballyIfPossible: deleteGloballyIfPossible)
    }
}

/// Delete for everyone on a secret chat: the peer only clears its copy when it receives a clear-history service message,
/// and a service message is not sent once the chat is terminated (Mercurygram 01230d2c1). So the flush goes out first and
/// the chat turns terminated only after discardEncryption was requested. Without the flush, or when the chat cannot
/// send, it terminates right away as before.
enum SecretChatTerminationPlan: Equatable {
    case terminateNow
    case flushHistoryThenTerminate(layer: SecretChatLayer)
}

func secretChatTerminationPlan(embeddedState: SecretChatEmbeddedState, requestRemoteHistoryRemoval: Bool) -> SecretChatTerminationPlan {
    guard requestRemoteHistoryRemoval else {
        return .terminateNow
    }
    switch embeddedState {
        case .terminated, .handshake:
            return .terminateNow
        case .basicLayer:
            return .flushHistoryThenTerminate(layer: .layer8)
        case let .sequenceBasedLayer(sequenceState):
            return .flushHistoryThenTerminate(layer: sequenceState.layerNegotiationState.activeLayer.secretChatLayer)
    }
}

private func queueSecretChatTermination(transaction: Transaction, peerId: PeerId, state: SecretChatState, reportSpam: Bool, requestRemoteHistoryRemoval: Bool) {
    var updatedState = state
    let plan = secretChatTerminationPlan(embeddedState: state.embeddedState, requestRemoteHistoryRemoval: requestRemoteHistoryRemoval)
    if case let .flushHistoryThenTerminate(layer) = plan {
        updatedState = addSecretChatOutgoingOperation(transaction: transaction, peerId: peerId, operation: SecretChatOutgoingOperationContents.clearHistory(layer: layer, actionGloballyUniqueId: Int64.random(in: Int64.min ... Int64.max)), state: updatedState)
    }
    updatedState = addSecretChatOutgoingOperation(transaction: transaction, peerId: peerId, operation: SecretChatOutgoingOperationContents.terminate(reportSpam: reportSpam, requestRemoteHistoryRemoval: requestRemoteHistoryRemoval), state: updatedState)
    if plan == .terminateNow {
        updatedState = updatedState.withUpdatedEmbeddedState(.terminated)
    }
    if updatedState != state {
        transaction.setPeerChatState(peerId, state: updatedState)
        if let peer = transaction.getPeer(peerId) as? TelegramSecretChat {
            updatePeersCustom(transaction: transaction, peers: [peer.withUpdatedEmbeddedState(updatedState.embeddedState.peerState)], update: { _, updated in
                return updated
            })
        }
    }
}

func _internal_terminateSecretChat(transaction: Transaction, peerId: PeerId, requestRemoteHistoryRemoval: Bool) {
    if let state = transaction.getPeerChatState(peerId) as? SecretChatState, state.embeddedState != .terminated {
        queueSecretChatTermination(transaction: transaction, peerId: peerId, state: state, reportSpam: false, requestRemoteHistoryRemoval: requestRemoteHistoryRemoval)
    }
}

func _internal_removePeerChat(account: Account, transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, reportChatSpam: Bool, deleteGloballyIfPossible: Bool) {
    if let _ = transaction.getPeerChatInterfaceState(peerId) {
        transaction.setPeerChatInterfaceState(peerId, state: nil)
    }
    _internal_updateChatListFiltersInteractively(transaction: transaction, { filters in
        var updatedFilters: [ChatListFilter] = []
        for i in 0 ..< filters.count {
            let filter = filters[i]
            if case let .filter(id, title, emoticon, data) = filter {
                var updatedData = data
                if updatedData.includePeers.peers.contains(peerId) {
                    updatedData.includePeers.setPeers(data.includePeers.peers.filter { $0 != peerId })
                }
                if updatedData.excludePeers.contains(peerId) {
                    updatedData.excludePeers = data.excludePeers.filter { $0 != peerId }
                }
                updatedFilters.append(.filter(id: id, title: title, emoticon: emoticon, data: updatedData))
            } else {
                updatedFilters.append(filter)
            }
        }
        return updatedFilters
    })
    if peerId.namespace == Namespaces.Peer.SecretChat {
        if let state = transaction.getPeerChatState(peerId) as? SecretChatState, state.embeddedState != .terminated {
            queueSecretChatTermination(transaction: transaction, peerId: peerId, state: state, reportSpam: reportChatSpam, requestRemoteHistoryRemoval: deleteGloballyIfPossible)
        }
        _internal_clearHistory(transaction: transaction, mediaBox: mediaBox, peerId: peerId, threadId: nil, namespaces: .all)
        transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
        transaction.removeOrderedItemListItem(collectionId: Namespaces.OrderedItemList.RecentlySearchedPeerIds, itemId: RecentPeerItemId(peerId).rawValue)
    } else {
        cloudChatAddRemoveChatOperation(transaction: transaction, peerId: peerId, reportChatSpam: reportChatSpam, deleteGloballyIfPossible: deleteGloballyIfPossible)
        if peerId.namespace == Namespaces.Peer.CloudUser  {
            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
            _internal_clearHistory(transaction: transaction, mediaBox: mediaBox, peerId: peerId, threadId: nil, namespaces: .all)
        } else if peerId.namespace == Namespaces.Peer.CloudGroup {
            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
            _internal_clearHistory(transaction: transaction, mediaBox: mediaBox, peerId: peerId, threadId: nil, namespaces: .all)
        } else {
            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
        }
    }
    transaction.removeOrderedItemListItem(collectionId: Namespaces.OrderedItemList.RecentlySearchedPeerIds, itemId: RecentPeerItemId(peerId).rawValue)
    
    if peerId.namespace == Namespaces.Peer.CloudChannel {
        // Leaving takes the channel out of News (Remove from News leaves a light join). Stored now: the leave is only
        // queued here, and its updates may not carry the channel at all.
        _internal_storeLocalInNews(transaction: transaction, accountPeerId: account.peerId, channelId: peerId, isInNews: false)
        transaction.clearItemCacheCollection(collectionId: Namespaces.CachedItemCollection.cachedGroupCallDisplayAsPeers)
    }
}

func _internal_getFutureCreatorAfterLeave(account: Account, peerId: EnginePeer.Id) -> Signal<EnginePeer?, NoError> {
    return account.postbox.transaction { transaction in
        return transaction.getPeer(peerId).flatMap(apiInputPeer)
    }
    |> mapToSignal { peer in
        guard let peer else {
            return .single(nil)
        }
        return account.network.request(Api.functions.messages.getFutureChatCreatorAfterLeave(peer: peer))
        |> map(Optional.init)
        |> `catch` { _ in
            return .single(nil)
        }
        |> map { user in
            return user.flatMap { TelegramUser(user: $0) }.map(EnginePeer.init)
        }
    }
}
