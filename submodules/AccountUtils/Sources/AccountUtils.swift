import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext

public let maximumNumberOfAccounts = 3
public let maximumPremiumNumberOfAccounts = 4

public func activeAccountsAndPeers(context: AccountContext, includePrimary: Bool = false) -> Signal<((AccountContext, EnginePeer)?, [(AccountContext, EnginePeer, Int32)]), NoError> {
    let sharedContext = context.sharedContext
    return context.sharedContext.activeAccountContexts
    |> mapToSignal { primary, activeAccounts, _ -> Signal<((AccountContext, EnginePeer)?, [(AccountContext, EnginePeer, Int32)]), NoError> in
        var accounts: [Signal<(AccountContext, EnginePeer, Int32)?, NoError>] = []
        func accountWithPeer(_ context: AccountContext, includeUnreadCount: Bool) -> Signal<(AccountContext, EnginePeer, Int32)?, NoError> {
            let unreadCount: Signal<Int32, NoError>
            if includeUnreadCount {
                unreadCount = renderedTotalUnreadCount(accountManager: sharedContext.accountManager, engine: context.engine)
                |> map { $0.0 }
            } else {
                // The primary's count is dropped from the result below; observing it only re-emitted
                // an unchanged value on every badge change.
                unreadCount = .single(0)
            }
            return combineLatest(context.account.postbox.peerView(id: context.account.peerId), unreadCount)
            |> map { view, totalUnreadCount -> (EnginePeer?, Int32) in
                return (view.peers[view.peerId].flatMap(EnginePeer.init), totalUnreadCount)
            }
            |> distinctUntilChanged { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return false
                }
                if lhs.1 != rhs.1 {
                    return false
                }
                return true
            }
            |> map { peer, totalUnreadCount -> (AccountContext, EnginePeer, Int32)? in
                if let peer = peer {
                    return (context, peer, totalUnreadCount)
                } else {
                    return nil
                }
            }
        }
        for (_, context, _) in activeAccounts {
            accounts.append(accountWithPeer(context, includeUnreadCount: includePrimary || context.account.id != primary?.account.id))
        }
        
        return combineLatest(accounts)
        |> map { accounts -> ((AccountContext, EnginePeer)?, [(AccountContext, EnginePeer, Int32)]) in
            var primaryRecord: (AccountContext, EnginePeer)?
            if let first = accounts.filter({ $0?.0.account.id == primary?.account.id }).first, let (account, peer, _) = first {
                primaryRecord = (account, peer)
            }
            let accountRecords: [(AccountContext, EnginePeer, Int32)] = (includePrimary ? accounts : accounts.filter({ $0?.0.account.id != primary?.account.id })).compactMap({ $0 })
            return (primaryRecord, accountRecords)
        }
    }
}
