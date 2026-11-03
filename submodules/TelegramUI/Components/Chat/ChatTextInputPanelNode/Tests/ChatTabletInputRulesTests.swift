import XCTest
import Display
import ChatTextInputPanelNode

final class ChatTabletInputRulesTests: XCTestCase {
    // MARK: Sticker panel expansion (mic vs up-chevron)

    /// iPad: the microphone stays while stickers are open and the panel is not stretched to the whole chat.
    func test_regular_noExpansion() {
        XCTAssertFalse(chatMediaInputAllowsExpansion(widthClass: .regular, deviceType: .tablet))
    }

    /// iPhone (and compact iPad windows): the up-chevron and stretching stay as upstream.
    func test_compact_expansionAsUpstream() {
        XCTAssertTrue(chatMediaInputAllowsExpansion(widthClass: .compact, deviceType: .phone))
        XCTAssertTrue(chatMediaInputAllowsExpansion(widthClass: .compact, deviceType: .tablet))
        XCTAssertTrue(chatMediaInputAllowsExpansion(widthClass: nil, deviceType: nil))
    }

    /// iPhone Duo unfolded in landscape is regular width, but a phone: the up-chevron and stretching stay.
    func test_regularWidthPhone_expansionAsUpstream() {
        XCTAssertTrue(chatMediaInputAllowsExpansion(widthClass: .regular, deviceType: .phone))
        XCTAssertTrue(chatMediaInputAllowsExpansion(widthClass: .regular, deviceType: nil))
    }

    // MARK: Esc

    /// Split view: nothing focused, or the chat's own text field focused: the chat handles Esc.
    func test_escapeKey_tablet_chatHandlesIt() {
        XCTAssertTrue(chatHandlesEscapeKey(deviceType: .tablet, firstResponderIsOutsideChat: false))
    }

    /// Split view, typing in the chat list's search field: its Esc (close the search) must win, so the chat
    /// does not add one that would replace it.
    func test_escapeKey_focusOutsideTheChat_leavesItToTheChatList() {
        XCTAssertFalse(chatHandlesEscapeKey(deviceType: .tablet, firstResponderIsOutsideChat: true))
    }

    /// iPhone (iPhone Duo included) keeps upstream: the chat adds no Esc.
    func test_escapeKey_phone_isUpstream() {
        XCTAssertFalse(chatHandlesEscapeKey(deviceType: .phone, firstResponderIsOutsideChat: false))
        XCTAssertFalse(chatHandlesEscapeKey(deviceType: nil, firstResponderIsOutsideChat: false))
    }

    func test_escape_withNothingOpen_leavesTheChat() {
        XCTAssertEqual(chatEscapeAction(ChatEscapeState()), .navigateBack)
    }

    func test_escape_cannotLeave_doesNothing() {
        XCTAssertNil(chatEscapeAction(ChatEscapeState(canNavigateBack: false)))
    }

    /// Each press steps back one level, innermost first.
    func test_escape_order() {
        var state = ChatEscapeState(isEditing: true, hasReply: true, hasForward: true, isMediaInputOpen: true, isSearchActive: true, isSelecting: true, canNavigateBack: true)
        XCTAssertEqual(chatEscapeAction(state), .cancelEditing)
        state.isEditing = false
        XCTAssertEqual(chatEscapeAction(state), .cancelReply)
        state.hasReply = false
        XCTAssertEqual(chatEscapeAction(state), .cancelForward)
        state.hasForward = false
        XCTAssertEqual(chatEscapeAction(state), .closeMediaInput)
        state.isMediaInputOpen = false
        XCTAssertEqual(chatEscapeAction(state), .closeSearch)
        state.isSearchActive = false
        XCTAssertEqual(chatEscapeAction(state), .cancelSelection)
        state.isSelecting = false
        XCTAssertEqual(chatEscapeAction(state), .navigateBack)
    }

    func test_escape_singleStates() {
        XCTAssertEqual(chatEscapeAction(ChatEscapeState(isMediaInputOpen: true)), .closeMediaInput)
        XCTAssertEqual(chatEscapeAction(ChatEscapeState(isSelecting: true, canNavigateBack: false)), .cancelSelection)
        XCTAssertEqual(chatEscapeAction(ChatEscapeState(hasReply: true, canNavigateBack: false)), .cancelReply)
    }
}
