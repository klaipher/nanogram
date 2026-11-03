import XCTest
import Display
import ChatTextInputPanelNode

final class ChatTabletInputRulesTests: XCTestCase {
    // MARK: Sticker panel expansion (mic vs up-chevron)

    /// iPad: the microphone stays while stickers are open and the panel is not stretched to the whole chat.
    func test_regular_noExpansion() {
        XCTAssertFalse(chatMediaInputAllowsExpansion(widthClass: .regular))
    }

    /// iPhone (and compact iPad windows): the up-chevron and stretching stay as upstream.
    func test_compact_expansionAsUpstream() {
        XCTAssertTrue(chatMediaInputAllowsExpansion(widthClass: .compact))
        XCTAssertTrue(chatMediaInputAllowsExpansion(widthClass: nil))
    }

    // MARK: Esc

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
