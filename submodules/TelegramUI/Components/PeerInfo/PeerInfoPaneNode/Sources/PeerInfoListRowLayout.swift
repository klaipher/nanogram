import Foundation
import UIKit

/// The size and insets a profile list row (Files, Music, Voice, Links) was last laid out for.
///
/// SparseItemGrid calls `update(size:insets:)` on every visible row on every scroll tick. A row's message item is
/// fixed between binds, so laying it out again for the same size and insets produces the same layout; this tells the
/// row when it can skip that work (up to 12 ms of main thread per tick on device).
public struct PeerInfoListRowLayout {
    private var applied: (size: CGSize, insets: UIEdgeInsets)?

    public init() {
    }

    /// Call after laying the row out (bind, or an update that did lay out).
    public mutating func didLayout(size: CGSize, insets: UIEdgeInsets) {
        self.applied = (size, insets)
    }

    /// Whether an update for `size` and `insets` has to lay the row out again.
    public func needsLayout(size: CGSize, insets: UIEdgeInsets) -> Bool {
        guard let applied = self.applied else {
            return true
        }
        return applied.size != size || applied.insets != insets
    }
}
