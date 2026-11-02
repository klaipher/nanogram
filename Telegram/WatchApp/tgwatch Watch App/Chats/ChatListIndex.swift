@preconcurrency import TDShim

/// Every chat list's chats in display order, and its unread total, kept up to date one chat at a
/// time. The projection used to scan and sort the whole chat cache (it only grows: TDLib sends
/// `updateNewChat` for every chat it touches) and scan it again per folder pill, on every update
/// burst.
///
/// Order: highest `order` first (TDLib's encoding puts pinned chats on top), then highest chat
/// id. TDLib orders are unique within a list except the 0 a just-added chat carries until its
/// position arrives; the old full sort left those ties in dictionary order.
struct ChatListIndex {
    struct Entry: Equatable {
        let order: Int64
        let chatId: Int64

        /// True when `self` is shown above `other`.
        func precedes(_ other: Entry) -> Bool {
            order != other.order ? order > other.order : chatId > other.chatId
        }
    }

    private var lists: [ChatListKey: [Entry]] = [:]
    private var unread: [ChatListKey: Int] = [:]

    func count(_ key: ChatListKey) -> Int { lists[key]?.count ?? 0 }

    func unreadCount(_ key: ChatListKey) -> Int { unread[key] ?? 0 }

    /// The first `limit` chats of the list, in display order.
    func top(_ key: ChatListKey, limit: Int) -> ArraySlice<Entry> {
        guard let entries = lists[key] else { return [] }
        return entries.prefix(limit)
    }

    /// Moves one chat from its `old` state to its `new` one (nil: not cached).
    mutating func update(from old: CachedChat?, to new: CachedChat?) {
        guard let id = new?.id ?? old?.id else { return }
        let before = Self.positions(of: old)
        let after = Self.positions(of: new)
        for (key, order) in before where after[key] != order {
            remove(Entry(order: order, chatId: id), from: key)
        }
        for (key, order) in after where before[key] != order {
            insert(Entry(order: order, chatId: id), into: key)
        }
        if let old {
            for key in before.keys { unread[key, default: 0] -= old.unreadCount }
        }
        if let new {
            for key in after.keys { unread[key, default: 0] += new.unreadCount }
        }
    }

    /// The chat's order in each list it is in. As in the projection, the first position for a
    /// list counts.
    private static func positions(of chat: CachedChat?) -> [ChatListKey: Int64] {
        guard let chat else { return [:] }
        var out: [ChatListKey: Int64] = [:]
        out.reserveCapacity(chat.positions.count)
        for position in chat.positions {
            let key = ChatListKey(position.list)
            if out[key] == nil { out[key] = position.order.rawValue }
        }
        return out
    }

    /// First index whose entry does not precede `entry`.
    private static func insertionIndex(of entry: Entry, in entries: [Entry]) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].precedes(entry) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private mutating func insert(_ entry: Entry, into key: ChatListKey) {
        var entries = lists.removeValue(forKey: key) ?? []
        entries.insert(entry, at: Self.insertionIndex(of: entry, in: entries))
        lists[key] = entries
    }

    private mutating func remove(_ entry: Entry, from key: ChatListKey) {
        guard var entries = lists.removeValue(forKey: key) else { return }
        let i = Self.insertionIndex(of: entry, in: entries)
        if i < entries.count, entries[i] == entry {
            entries.remove(at: i)
        }
        lists[key] = entries
    }
}
