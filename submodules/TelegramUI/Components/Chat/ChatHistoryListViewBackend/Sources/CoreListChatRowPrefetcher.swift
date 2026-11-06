import Foundation
import UIKit
import SwiftSignalKit
import Display
import ChatMessageItemImpl
import ChatControllerInteraction
import ChatRowPrep

/// "Chat rows: prepare layout ahead". Runs the build of a chat row (node creation, `asyncLayout`, the text layout and sizes)
/// on a background queue for the rows that are about to enter the load band, and hands the finished node to the host view
/// when CoreList asks for that row.
///
/// Why this is safe to bolt on: the job calls the same `ChatMessageItemImpl.nodeConfiguredForParams` that the host calls on
/// the main thread today. Called off the main thread it runs the layout inline, which is how `ListViewImpl` builds every
/// node, and delivers `(node, apply)` to the main queue; the host then runs the same `apply` it would have run. Heights come
/// from the same computation, only earlier. A result is used only when the whole key is equal (see `ChatRowPrepKey`), so a
/// stale result is never used, and anything else falls back to today's synchronous path.
///
/// Main thread only, except the job body.
final class CoreListChatRowPrefetcher {
    typealias Key = ChatRowPrepKey<ListViewItemNeighbors>

    struct Prepared {
        let node: ListViewItemNode
        let apply: () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)
    }

    /// One row to prepare: everything the job needs, captured on the main thread.
    struct Candidate {
        let key: Key
        let item: ChatMessageItemImpl
        let params: ListViewItemLayoutParams
        let neighbors: ListViewItemNeighbors
    }

    /// Rows ahead of the loaded edge that are prepared.
    static let lookahead = 3

    private let cache: ChatRowPrepCache<ListViewItemNeighbors, Prepared>
    private let queue = Queue(name: "org.nanogram.chat-row-prefetch", qos: .userInitiated)

    init() {
        self.cache = ChatRowPrepCache<ListViewItemNeighbors, Prepared>(limits: ChatRowPrepCache<ListViewItemNeighbors, Prepared>.Limits(maxEntries: 8, timeToLive: 5.0))
    }

    var preparedCount: Int {
        return self.cache.count
    }

    /// The key of `item` as laid out with these inputs; nil for items that are not chat messages (they are not prepared).
    static func key(item: ListViewItem, stableId: UInt64, stableVersion: Int, width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, neighbors: ListViewItemNeighbors, synchronousLoads: Bool) -> Key? {
        guard let item = item as? ChatMessageItemImpl else {
            return nil
        }
        return Key(
            stableId: stableId,
            stableVersion: stableVersion,
            itemToken: ObjectIdentifier(item),
            width: width,
            leftInset: leftInset,
            rightInset: rightInset,
            neighbors: neighbors,
            themeToken: ObjectIdentifier(item.presentationData),
            fontSize: item.presentationData.fontSize.rawValue,
            interactionEpoch: item.controllerInteraction.rowPrepEpoch,
            rotated: item.controllerInteraction.chatIsRotated,
            synchronousLoads: synchronousLoads
        )
    }

    /// Keeps exactly the rows in `candidates` (cancelling and dropping the rest) and starts a job for each one that is not
    /// prepared yet.
    func plan(_ candidates: [Candidate]) {
        self.cache.retain(keys: candidates.map { $0.key })
        for candidate in candidates {
            guard case let .started(ticket) = self.cache.claim(candidate.key) else {
                continue
            }
            let key = candidate.key
            let item = candidate.item
            let params = candidate.params
            let neighbors = candidate.neighbors
            self.queue.async { [weak self] in
                if ticket.isCancelled {
                    Queue.mainQueue().async {
                        self?.cache.fail(ticket: ticket, key: key)
                    }
                    return
                }
                let state = NanogramSignposts.begin(ChatRowPrepSignposts.prefetchCompute)
                // Off the main thread this builds the node and runs the layout inline, then delivers on the main queue.
                item.nodeConfiguredForParams(async: { f in f() }, params: params, synchronousLoads: key.synchronousLoads, neighbors: neighbors, completion: { node, apply in
                    self?.cache.complete(ticket: ticket, key: key, payload: Prepared(node: node, apply: apply))
                })
                NanogramSignposts.end(ChatRowPrepSignposts.prefetchCompute, state)
            }
        }
    }

    /// The prepared node for exactly `key`, if there is one.
    func take(_ key: Key) -> Prepared? {
        switch self.cache.take(key) {
        case let .hit(prepared):
            ChatRowPrepSignposts.prefetchHit()
            return prepared
        case .miss:
            ChatRowPrepSignposts.prefetchMiss()
            return nil
        }
    }

    /// A new width, theme, font size or a left chat: nothing prepared can be used.
    func evictAll() {
        self.cache.evictAll()
    }
}
