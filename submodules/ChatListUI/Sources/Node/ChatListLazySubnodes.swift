import Foundation

/// Children of mainContentContainerNode in the order ChatListItemNode.init adds them. Do not reorder.
enum ChatListMainContentChild: Int, CaseIterable {
    case title, author, text, date, status, pinnedIcon, badge, mentionBadge, hiddenPeerIcon, mutedIcon
    
    /// `text` can be re-added elsewhere (compound button), so it never anchors an insertion.
    var anchorsInsertions: Bool {
        return self != .text
    }
}

/// The parts of a chat list row that an ordinary row never shows. They join
/// the row's node hierarchy (and so get a view or layer) the first time the row needs them visible.
enum ChatListLazySubnode: Int, CaseIterable {
    case communityShadow, status, pinnedIcon, badge, mentionBadge, hiddenPeerIcon, mutedIcon, onlineDot
    
    var mainContentChild: ChatListMainContentChild? {
        switch self {
        case .communityShadow, .onlineDot:
            return nil
        case .status:
            return .status
        case .pinnedIcon:
            return .pinnedIcon
        case .badge:
            return .badge
        case .mentionBadge:
            return .mentionBadge
        case .hiddenPeerIcon:
            return .hiddenPeerIcon
        case .mutedIcon:
            return .mutedIcon
        }
    }
    
    /// The ChatListItemNode stored property name (the ledger test compares these).
    var propertyName: String {
        switch self {
        case .communityShadow:
            return "communityAvatarShadowNode"
        case .status:
            return "statusNode"
        case .pinnedIcon:
            return "pinnedIconNode"
        case .badge:
            return "badgeNode"
        case .mentionBadge:
            return "mentionBadgeNode"
        case .hiddenPeerIcon:
            return "hiddenPeerIconNode"
        case .mutedIcon:
            return "mutedIconNode"
        case .onlineDot:
            return "onlineNode"
        }
    }
}

struct ChatListLazySubnodeSet: OptionSet {
    let rawValue: UInt16
    
    init(_ s: ChatListLazySubnode) {
        self.rawValue = 1 << UInt16(s.rawValue)
    }
    
    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
    
    static let all = ChatListLazySubnodeSet(rawValue: (1 << UInt16(ChatListLazySubnode.allCases.count)) - 1)
}

enum ChatListSubnodePlacement: Equatable {
    case above(ChatListMainContentChild)
    case first
}

/// Nearest lower-ordered child in `attached` that may anchor; `.first` only if none (unreachable in production:
/// title/author/date are always attached).
func chatListLazyPlacement(for target: ChatListMainContentChild, attached: Set<ChatListMainContentChild>) -> ChatListSubnodePlacement {
    var candidate = target.rawValue - 1
    while candidate >= 0 {
        if let child = ChatListMainContentChild(rawValue: candidate), child.anchorsInsertions, attached.contains(child) {
            return .above(child)
        }
        candidate -= 1
    }
    return .first
}

enum ChatListSubnodeDecision {
    case eager
    case lazy
    case attachedOnDemand
    case neverInHierarchy
}
