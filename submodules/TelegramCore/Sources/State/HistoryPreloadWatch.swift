import Foundation
import Postbox

func historyPreloadKeepsWatching(hasHole: Bool) -> Bool {
    return hasHole
}

func historyPreloadNeedsWatching(isWatching: Bool, previousIndex: ChatListIndex?, index: ChatListIndex?) -> Bool {
    return !isWatching && previousIndex != index
}
