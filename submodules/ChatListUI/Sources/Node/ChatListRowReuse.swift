import Foundation
import UIKit
import AsyncDisplayKit
import AccountContext
import TelegramCore

/// What the row reuse decides about an item, as plain values. A row is reused only for an ordinary chat row of the
/// main list, the folders and the archive list: anything that changes the row's structure (topics, communities, side
/// lists, editing, search, promos, ...) makes the item ineligible, and the row is destroyed as before.
struct ChatListRowReuseFacts: Equatable {
    enum ContentKind: Equatable {
        case peer
        case groupReference
        case loading
    }
    
    var contentKind: ContentKind = .peer
    var isChatListIndex: Bool = true
    var isCommunityPeer: Bool = false
    var isCommunityMember: Bool = false
    var isMonoforum: Bool = false
    var displayAsMessage: Bool = false
    var displayAsTopicList: Bool = false
    var hasTopForumTopicItems: Bool = false
    var hasThreadInfo: Bool = false
    var hasForumTopicData: Bool = false
    var hasCustomMessageListData: Bool = false
    var isSideListAllThreadsItem: Bool = false
    var isSideListCompactPeerRow: Bool = false
    var isSideListMode: Bool = false
    var isInlineMode: Bool = false
    var hasInlineNavigation: Bool = false
    var isSearchMode: Bool = false
    var hasSearchHighlight: Bool = false
    var useCommunityViewLayout: Bool = false
    var editing: Bool = false
    var selected: Bool = false
    var hasActiveRevealControls: Bool = false
    var hiddenOffset: Bool = false
    var hasPromo: Bool = false
    
    /// Ordinary facts: an ordinary chat row.
    init() {
    }
    
    init(item: ChatListItem) {
        switch item.content {
        case .loading:
            self.contentKind = .loading
        case .groupReference:
            self.contentKind = .groupReference
        case let .peer(peerData):
            self.contentKind = .peer
            if let mainPeer = peerData.peer.peer {
                if case .community = mainPeer {
                    self.isCommunityPeer = true
                }
                if case let .channel(channel) = mainPeer, channel.isMonoForum {
                    self.isMonoforum = true
                }
                self.isCommunityMember = mainPeer.containerPeerId != nil
            }
            self.displayAsMessage = peerData.displayAsMessage
            self.displayAsTopicList = peerData.displayAsTopicList
            self.hasTopForumTopicItems = !peerData.topForumTopicItems.isEmpty
            self.hasThreadInfo = peerData.threadInfo != nil
            self.hasForumTopicData = peerData.forumTopicData != nil
            self.hasCustomMessageListData = peerData.customMessageListData != nil
            self.isSideListAllThreadsItem = peerData.isSideListAllThreadsItem
            self.hasPromo = peerData.promoInfo != nil
        }
        if case .chatList = item.index {
            self.isChatListIndex = true
        } else {
            self.isChatListIndex = false
        }
        self.isSideListCompactPeerRow = item.isSideListCompactPeerRow
        self.isSideListMode = item.interaction.isSideListMode
        self.isInlineMode = item.interaction.isInlineMode
        self.hasInlineNavigation = item.interaction.inlineNavigationLocation != nil
        self.isSearchMode = item.interaction.isSearchMode
        self.hasSearchHighlight = item.interaction.searchTextHighightState != nil
        self.useCommunityViewLayout = item.useCommunityViewLayout
        self.editing = item.editing
        self.selected = item.selected
        self.hasActiveRevealControls = item.hasActiveRevealControls
        self.hiddenOffset = item.hiddenOffset
    }
    
    var isEligible: Bool {
        if self.contentKind != .peer || !self.isChatListIndex {
            return false
        }
        let flags: [Bool] = [
            self.isCommunityPeer, self.isCommunityMember, self.isMonoforum, self.displayAsMessage, self.displayAsTopicList,
            self.hasTopForumTopicItems, self.hasThreadInfo, self.hasForumTopicData, self.hasCustomMessageListData,
            self.isSideListAllThreadsItem, self.isSideListCompactPeerRow, self.isSideListMode, self.isInlineMode,
            self.hasInlineNavigation, self.isSearchMode, self.hasSearchHighlight, self.useCommunityViewLayout,
            self.editing, self.selected, self.hasActiveRevealControls, self.hiddenOffset, self.hasPromo
        ]
        return !flags.contains(true)
    }
}

extension ChatListNode {
    /// Whether the rows of a list built with these parameters may be pooled and reused. Search, pickers, peer-info
    /// lists, forums, saved messages, side lists, previews and inline lists keep building new rows.
    static func supportsRowReuse(mode: ChatListNodeMode, location: ChatListControllerLocation, isSideList: Bool, previewing: Bool, isInlineMode: Bool) -> Bool {
        guard case .chatList = mode else {
            return false
        }
        guard case .chatList = location else {
            return false
        }
        return !isSideList && !previewing && !isInlineMode
    }
}

/// Why a row cannot go back into the pool. The checks are pure reads.
enum ChatListRowReuseRefusal: Equatable {
    case tainted
    case notEligible
    case videoAvatar
    case topics
    case exoticChild
    case removalAnimation
    case highlighted
    case reveal
    case typing
    case nodeState
    case animating
}

/// What `ChatListItemNode.prepareForRowReuse` does with a stored property (the Mirror ledger tests compare the key sets).
enum ChatListRowReuseTreatment {
    /// Never changes after init.
    case constant
    /// Written back to its initial value.
    case reset
    /// A view or node added by the apply: removed and set to nil.
    case removeAndNil
    /// A row that has it set is not reused.
    case refuse
    /// The non-animated apply of the next item rewrites it before it is shown.
    case rewrittenByApply
    /// A subnode whose properties are restored from the values captured in `init`.
    case restoredDefault
}

/// Alpha, visibility, transforms and frame of a fixed subnode as `ChatListItemNode.init` leaves them.
struct ChatListRowSubnodeDefault {
    let node: ASDisplayNode
    let alpha: CGFloat
    let isHidden: Bool
    let transform: CATransform3D
    let subnodeTransform: CATransform3D
    let frame: CGRect
    let isImageNode: Bool
}
