import XCTest
import Postbox
import TelegramCore
import AccountContext
@testable import ChatListUI

final class ChatListRowReuseEligibilityTests: XCTestCase {
    private let boolFacts: [(String, WritableKeyPath<ChatListRowReuseFacts, Bool>)] = [
        ("isCommunityPeer", \.isCommunityPeer),
        ("isCommunityMember", \.isCommunityMember),
        ("isMonoforum", \.isMonoforum),
        ("displayAsMessage", \.displayAsMessage),
        ("displayAsTopicList", \.displayAsTopicList),
        ("hasTopForumTopicItems", \.hasTopForumTopicItems),
        ("hasThreadInfo", \.hasThreadInfo),
        ("hasForumTopicData", \.hasForumTopicData),
        ("hasCustomMessageListData", \.hasCustomMessageListData),
        ("isSideListAllThreadsItem", \.isSideListAllThreadsItem),
        ("isSideListCompactPeerRow", \.isSideListCompactPeerRow),
        ("isSideListMode", \.isSideListMode),
        ("isInlineMode", \.isInlineMode),
        ("hasInlineNavigation", \.hasInlineNavigation),
        ("isSearchMode", \.isSearchMode),
        ("hasSearchHighlight", \.hasSearchHighlight),
        ("useCommunityViewLayout", \.useCommunityViewLayout),
        ("editing", \.editing),
        ("selected", \.selected),
        ("hasActiveRevealControls", \.hasActiveRevealControls),
        ("hiddenOffset", \.hiddenOffset),
        ("hasPromo", \.hasPromo)
    ]
    
    func testOrdinaryFactsAreEligible() {
        XCTAssertTrue(ChatListRowReuseFacts().isEligible)
    }
    
    func testEachFactAloneMakesTheRowIneligible() {
        for (name, keyPath) in self.boolFacts {
            var facts = ChatListRowReuseFacts()
            facts[keyPath: keyPath] = true
            XCTAssertFalse(facts.isEligible, "\(name) must make a row ineligible")
        }
        var groupReference = ChatListRowReuseFacts()
        groupReference.contentKind = .groupReference
        XCTAssertFalse(groupReference.isEligible)
        var loading = ChatListRowReuseFacts()
        loading.contentKind = .loading
        XCTAssertFalse(loading.isEligible)
        var forumIndex = ChatListRowReuseFacts()
        forumIndex.isChatListIndex = false
        XCTAssertFalse(forumIndex.isEligible)
    }
    
    func testTableCoversEveryFact() {
        var labels = Set<String>()
        for child in Mirror(reflecting: ChatListRowReuseFacts()).children {
            if let label = child.label {
                labels.insert(label)
            }
        }
        labels.remove("contentKind")
        labels.remove("isChatListIndex")
        XCTAssertEqual(labels, Set(self.boolFacts.map { $0.0 }), "a fact was added to ChatListRowReuseFacts without a case in this table")
    }
    
    func testListSupportsRowReuse() {
        let forumPeerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(100))
        let chatListMode = ChatListNodeMode.chatList(appendContacts: true)
        XCTAssertTrue(ChatListNode.supportsRowReuse(mode: chatListMode, location: .chatList(groupId: .root), isSideList: false, previewing: false, isInlineMode: false))
        XCTAssertTrue(ChatListNode.supportsRowReuse(mode: chatListMode, location: .chatList(groupId: .archive), isSideList: false, previewing: false, isInlineMode: false))
        
        let peersMode = ChatListNodeMode.peers(filter: [], isSelecting: false, additionalCategories: [], topPeers: [], chatListFilters: nil, displayAutoremoveTimeout: false, displayPresence: false)
        let peerTypeMode = ChatListNodeMode.peerType(type: [], hasCreate: false, excludedPeerIds: [], includeCommunities: false)
        XCTAssertFalse(ChatListNode.supportsRowReuse(mode: peersMode, location: .chatList(groupId: .root), isSideList: false, previewing: false, isInlineMode: false))
        XCTAssertFalse(ChatListNode.supportsRowReuse(mode: peerTypeMode, location: .chatList(groupId: .root), isSideList: false, previewing: false, isInlineMode: false))
        XCTAssertFalse(ChatListNode.supportsRowReuse(mode: chatListMode, location: .forum(peerId: forumPeerId), isSideList: false, previewing: false, isInlineMode: false))
        XCTAssertFalse(ChatListNode.supportsRowReuse(mode: chatListMode, location: .savedMessagesChats(peerId: forumPeerId), isSideList: false, previewing: false, isInlineMode: false))
        XCTAssertFalse(ChatListNode.supportsRowReuse(mode: chatListMode, location: .chatList(groupId: .root), isSideList: true, previewing: false, isInlineMode: false))
        XCTAssertFalse(ChatListNode.supportsRowReuse(mode: chatListMode, location: .chatList(groupId: .root), isSideList: false, previewing: true, isInlineMode: false))
        XCTAssertFalse(ChatListNode.supportsRowReuse(mode: chatListMode, location: .chatList(groupId: .root), isSideList: false, previewing: false, isInlineMode: true))
    }
    
    func testFlagDefaultsOff() {
        XCTAssertFalse(ChatListRowExperiments.rowReuse)
    }
}
