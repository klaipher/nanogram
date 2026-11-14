import Foundation
@preconcurrency import TDShim

/// Pure value type owning the loaded contiguous range of cached messages for a
/// single chat. The single home for the gap-prevention invariant: ids in `cache`
/// always form one contiguous range with respect to TDLib's message-id ordering.
///
/// Anchor semantics: `.tail` means "open at the chat tail"; `.messageId(X)` means
/// "open with X as the entry point" (the unread-divider use case). The anchor is
/// purely informational after construction; bounds are tracked by `loadedLowest/HighestId`.
///
/// `unreadDividerAfterId` is frozen at construction. The divider row in the
/// projection renders between this id and the next-newer message. Live
/// `updateChatReadInbox` does NOT mutate this field — the divider stays where it
/// was when the chat opened.
struct MessageWindow: Equatable {
    enum Anchor: Equatable { case tail, messageId(Int64) }

    /// Bumped on every change to `cache` (not on file updates, which never touch the window), so a consumer
    /// can reuse work derived from the messages (the sorted array) until it changes.
    private(set) var revision = 0
    private(set) var cache: [Int64: CachedMessage] = [:] {
        didSet { revision &+= 1 }
    }
    private(set) var loadedLowestId: Int64? = nil
    private(set) var loadedHighestId: Int64? = nil
    /// True until an older-fetch comes back empty. Defensively flipped true when
    /// the cache empties (e.g. via a delete-all) so the next interaction re-fills.
    private(set) var hasOlder: Bool = true
    /// True once `loadedHighestId == chat.lastMessage?.id` or a newer-fetch is empty.
    private(set) var reachesChatTail: Bool = false

    /// Frozen at construction; never mutated thereafter. The divider row renders
    /// between this id and the first message with `id > unreadDividerAfterId`.
    let unreadDividerAfterId: Int64?
    let anchor: Anchor
    let halfLimit: Int

    init(anchor: Anchor, halfLimit: Int, unreadDividerAfterId: Int64?) {
        self.anchor = anchor
        self.halfLimit = halfLimit
        self.unreadDividerAfterId = unreadDividerAfterId
    }

    /// The row id the view should scroll to on first `.loaded` render. Returns
    /// the unread-divider row id ("unread-<dividerAnchor>") when the divider is
    /// set AND the loaded cache contains at least one message above the divider.
    /// Returns nil otherwise — caller falls back to scrolling the last row to
    /// `.bottom`.
    var initialScrollTargetId: String? {
        guard let divider = unreadDividerAfterId else { return nil }
        let hasAnyUnread = cache.keys.contains { $0 > divider }
        return hasAnyUnread ? "unread-\(divider)" : nil
    }

    // MARK: - Mutators

    mutating func extendInitial(_ messages: [CachedMessage], chatTailId: Int64?) {
        for m in messages { cache[m.id] = m }
        recomputeBounds()
        updateReachesChatTail(chatTailId: chatTailId)
    }

    mutating func extendOlder(_ messages: [CachedMessage]) {
        if messages.isEmpty { hasOlder = false; return }
        for m in messages { cache[m.id] = m }
        recomputeBounds()
    }

    mutating func extendNewer(_ messages: [CachedMessage], chatTailId: Int64?) {
        if messages.isEmpty { reachesChatTail = true; return }
        for m in messages { cache[m.id] = m }
        recomputeBounds()
        updateReachesChatTail(chatTailId: chatTailId)
    }

    /// Returns true if the message extends the window or was already present;
    /// false if the window doesn't reach the chat tail and the message can't be
    /// inserted without creating a gap. The caller bumps a jump-counter on false.
    mutating func tryInsertLive(_ message: CachedMessage) -> Bool {
        if cache[message.id] != nil { return true }
        if reachesChatTail {
            cache[message.id] = message
            recomputeBounds()
            return true
        }
        return false
    }

    mutating func applySendSucceeded(oldId: Int64, message: CachedMessage) {
        cache.removeValue(forKey: oldId)
        cache[message.id] = message
        recomputeBounds()
    }

    mutating func applySendFailed(oldId: Int64, message: CachedMessage) {
        cache.removeValue(forKey: oldId)
        cache[message.id] = message
        recomputeBounds()
    }

    mutating func applyContentUpdate(id: Int64, newContent: MessageContent) {
        guard let existing = cache[id] else { return }
        cache[id] = CachedMessage(
            id: existing.id, date: existing.date, editDate: existing.editDate,
            isOutgoing: existing.isOutgoing, senderId: existing.senderId,
            content: newContent, sendingState: existing.sendingState,
            replyTo: existing.replyTo
        )
    }

    /// Patches the cached `messagePoll` whose `poll.id` matches the updated poll
    /// (from `updatePoll`, which carries no message id). No-op if no such message
    /// is in the window. The scan is linear over a small (~30–60) window.
    mutating func applyPollUpdate(poll: Poll) {
        for (id, existing) in cache {
            guard case .messagePoll(let mp) = existing.content, mp.poll.id == poll.id else { continue }
            let rebuilt = MessagePoll(
                canAddOption: mp.canAddOption,
                description: mp.description,
                media: mp.media,
                poll: poll
            )
            cache[id] = CachedMessage(
                id: existing.id, date: existing.date, editDate: existing.editDate,
                isOutgoing: existing.isOutgoing, senderId: existing.senderId,
                content: .messagePoll(rebuilt),
                sendingState: existing.sendingState, replyTo: existing.replyTo
            )
            return
        }
    }

    mutating func applyDelete(ids: [Int64]) {
        for id in ids { cache.removeValue(forKey: id) }
        recomputeBounds()
        if cache.isEmpty { hasOlder = true }
    }

    /// Externally settable when `sendText` runs — sending implicitly pulls the
    /// view to the tail, so anything beyond `loadedHighestId` is no longer a "gap"
    /// from the user's perspective.
    mutating func markReachesChatTail() { reachesChatTail = true }

    mutating func markHasOlderFalse() { hasOlder = false }

    // MARK: - Trimming (WATCH-LIST-1)

    enum TrimEnd: Equatable {
        /// Drop the highest ids: the user is reading older history, far from the tail.
        case newest
        /// Drop the lowest ids: the user scrolled forward, away from the old end.
        case oldest
    }

    /// Keeps the window to about `limit` messages by dropping the end the user is not reading, so memory and
    /// per-update work stop growing with scroll depth. Messages still being sent or that failed to send are
    /// never dropped (their local ids sit at the newest end and the send-result update needs them), and the newest end
    /// stops at the first of them so the kept range stays contiguous.
    /// Dropping the newest end means the window no longer reaches the chat tail (`loadNewer` brings it back);
    /// dropping the oldest end means there is older history again. Returns how many messages were dropped.
    @discardableResult
    mutating func trim(toLimit limit: Int, droppingFrom end: TrimEnd) -> Int {
        let excess = cache.count - max(1, limit)
        guard excess > 0 else { return 0 }
        let ids = cache.keys.sorted()
        let candidates: [Int64] = (end == .newest) ? Array(ids.reversed()) : ids
        var dropped = 0
        for id in candidates {
            if dropped == excess { break }
            guard let message = cache[id] else { continue }
            if message.sendingState != .sent {
                // Unsent messages sit at the newest end. Dropping past one would leave it beside old history with
                // a gap between, so the newest end stops here; the oldest end just skips them.
                if end == .newest { break }
                continue
            }
            cache.removeValue(forKey: id)
            dropped += 1
        }
        guard dropped > 0 else { return 0 }
        recomputeBounds()
        switch end {
        case .newest: reachesChatTail = false
        case .oldest: hasOlder = true
        }
        return dropped
    }

    // MARK: - Internals

    private mutating func recomputeBounds() {
        loadedLowestId = cache.keys.min()
        loadedHighestId = cache.keys.max()
    }

    private mutating func updateReachesChatTail(chatTailId: Int64?) {
        guard let highest = loadedHighestId, let tail = chatTailId else { return }
        if highest >= tail { reachesChatTail = true }
    }
}
