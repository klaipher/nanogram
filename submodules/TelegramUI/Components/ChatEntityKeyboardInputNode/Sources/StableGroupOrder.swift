import Foundation
import Postbox

/// Orders the item groups of an emoji or sticker panel so that the groups the user may reorder keep a stable
/// order between updates. This ran on the main thread when the panel opened (`processStableItemGroupList`,
/// 14 ms in a trace) with `contains(where:)` and `first(where:)` over the whole list inside loops over the
/// list, comparing `AnyHashable` values: quadratic in the number of packs. This version builds a set and a
/// dictionary once and is linear. The result is identical to the former implementation.
enum StableGroupOrder {
    private static let topStaticGroups: Set<AnyHashable> = [AnyHashable("static"), AnyHashable("recent"), AnyHashable("featuredTop")]

    static func isReorderable(id: AnyHashable, isEmbedded: Bool, isFeatured: Bool) -> ItemCollectionId? {
        if isEmbedded || isFeatured {
            return nil
        }
        return id.base as? ItemCollectionId
    }

    /// - Parameters:
    ///   - groups: the groups of the new data.
    ///   - storedOrder: the order of reorderable collection ids stored by the previous call, if any.
    /// - Returns: the groups in display order and the order to store for the next call.
    static func process<Group>(
        groups: [Group],
        storedOrder: [ItemCollectionId]?,
        id: (Group) -> AnyHashable,
        isEmbedded: (Group) -> Bool,
        isFeatured: (Group) -> Bool
    ) -> (groups: [Group], order: [ItemCollectionId]) {
        let ids = groups.map(id)

        var nextIds: [ItemCollectionId] = []
        for (index, group) in groups.enumerated() {
            if let collectionId = isReorderable(id: ids[index], isEmbedded: isEmbedded(group), isFeatured: isFeatured(group)) {
                nextIds.append(collectionId)
            }
        }

        let stableOrder = storedOrder ?? nextIds
        var stableOrderSet = Set<AnyHashable>()
        for collectionId in stableOrder {
            stableOrderSet.insert(AnyHashable(collectionId))
        }

        var firstIndexById: [AnyHashable: Int] = [:]
        for (index, groupId) in ids.enumerated() {
            if firstIndexById[groupId] == nil {
                firstIndexById[groupId] = index
            }
        }

        var staticIsFirst = false
        for groupId in ids {
            if !topStaticGroups.contains(groupId) {
                break
            }
            if groupId == AnyHashable("static") {
                staticIsFirst = true
            }
        }

        var updated: [Group] = []
        var updatedIdSet = Set<AnyHashable>()
        var updatedIds: [AnyHashable] = []
        func append(_ group: Group, _ groupId: AnyHashable) {
            updated.append(group)
            updatedIdSet.insert(groupId)
            updatedIds.append(groupId)
        }

        for (index, group) in groups.enumerated() {
            let groupId = ids[index]
            if !(groupId.base is ItemCollectionId) {
                if groupId != AnyHashable("static") || staticIsFirst {
                    append(group, groupId)
                }
            } else {
                if isEmbedded(group) || isFeatured(group) {
                    continue
                }
                if !stableOrderSet.contains(groupId) {
                    append(group, groupId)
                }
            }
        }
        for collectionId in stableOrder {
            if let index = firstIndexById[AnyHashable(collectionId)] {
                append(groups[index], ids[index])
            }
        }
        for (index, group) in groups.enumerated() {
            if !updatedIdSet.contains(ids[index]) {
                append(group, ids[index])
            }
        }

        var order: [ItemCollectionId] = []
        for group in updated {
            if let collectionId = isReorderable(id: id(group), isEmbedded: isEmbedded(group), isFeatured: isFeatured(group)) {
                order.append(collectionId)
            }
        }
        return (updated, order)
    }
}
