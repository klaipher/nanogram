import Foundation

/// When a chat list transition makes its rows load avatars and message previews synchronously.
///
/// Synchronous loading keeps a freshly created screen from showing empty rows for a frame, but it
/// puts the decode of every inserted or updated row's avatar and preview on the main thread (a
/// 103 ms hang at a chat list update, 20-33 ms per update). It is kept for the cases where many
/// rows appear at once and the user would see them fill in: the first content of the list, a folder
/// switch, a jump to the top and a bulk insert. An incremental update (a new message moves a chat up,
/// a row changes) loads asynchronously; the row's existing content stays on screen while it does.
enum ChatListSynchronousLoadingPolicy {
    /// More inserted rows than this count as a bulk change (reload, search clear, large history).
    static let bulkInsertThreshold = 3

    /// `userIsScrolling` (finger down or coasting) with `asyncWhileScrolling` on: more rows arriving in bulk (paging in
    /// the next chats) is not a reason to decode their media previews on the main thread; that cost ~40 ms for one row
    /// in the 202611081037 hitch log. The first content, a folder switch and a jump still load synchronously.
    static func prefersSynchronousResourceLoading(isFirstTransition: Bool, filterChanged: Bool, scrollsToItem: Bool, insertedCount: Int, userIsScrolling: Bool = false, asyncWhileScrolling: Bool = false) -> Bool {
        if isFirstTransition || filterChanged || scrollsToItem {
            return true
        }
        if userIsScrolling && asyncWhileScrolling {
            return false
        }
        return insertedCount > bulkInsertThreshold
    }
}
