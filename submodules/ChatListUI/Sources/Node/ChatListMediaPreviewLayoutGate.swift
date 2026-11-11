import Foundation
import UIKit

/// Decides whether a chat list row's media preview thumbnail has to be laid out and drawn again. `updateLayout` runs on
/// every row layout (also in the stacks of a back swipe), and each call re-ran the image node's layout and apply, which
/// decodes the thumbnail synchronously. The preview's message and media are fixed for the node's life, so the size and the
/// media identity are the whole input.
struct ChatListMediaPreviewLayoutGate<MediaId: Hashable> {
    private var last: (size: CGSize, mediaId: MediaId)?

    /// True when the layout has to run for these arguments; the arguments are remembered then.
    mutating func shouldLayout(size: CGSize, mediaId: MediaId) -> Bool {
        if let last = self.last, last.size == size, last.mediaId == mediaId {
            return false
        }
        self.last = (size, mediaId)
        return true
    }
}
