import UIKit

/// Membership tests the scroll path runs on every window change, kept as pure functions so they can
/// be pinned against the straightforward quadratic versions they replaced.
enum ListMembership {
    /// The subviews of `subviews` that are not one of `keeping`, in the order `subviews` lists them.
    ///
    /// Replaces `subviews.filter { s in !keeping.contains { $0 === s } }`, which compared every
    /// subview against every kept view on each `render()`. Identity is reference identity, as before.
    static func staleSubviews(in subviews: [UIView], keeping: [UIView]) -> [UIView] {
        guard !subviews.isEmpty else { return [] }
        var keptIDs = Set<ObjectIdentifier>()
        keptIDs.reserveCapacity(keeping.count)
        for view in keeping {
            keptIDs.insert(ObjectIdentifier(view))
        }
        return subviews.filter { !keptIDs.contains(ObjectIdentifier($0)) }
    }

    /// Identities of `windowIdentities` that have an entry in `carries`.
    ///
    /// Replaces `Set(windowIdentities).intersection(carries.keys)`: no Set of the whole window is
    /// built, and nothing is hashed at all while there are no carries (the common scroll case).
    static func promotedIdentities<Carry>(windowIdentities: [AnyHashable],
                                          carries: [AnyHashable: Carry]) -> Set<AnyHashable> {
        guard !carries.isEmpty else { return [] }
        var promoted = Set<AnyHashable>()
        for identity in windowIdentities where carries[identity] != nil {
            promoted.insert(identity)
        }
        return promoted
    }
}
