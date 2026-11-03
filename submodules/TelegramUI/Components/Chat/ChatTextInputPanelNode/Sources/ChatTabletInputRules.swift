import Foundation
import Display

// Chat decisions for iPad (and a hardware keyboard) that differ from upstream Telegram, kept as pure functions so
// the upstream call sites change by a line each and the rules are unit-tested (`ChatTextInputPanelNodeTests`).

/// Whether the sticker/emoji/GIF panel can be stretched upwards (the up-chevron in the input row, and dragging
/// the panel). On iPhone the panel is short and stretching it is useful. On iPad the panel is keyboard-sized
/// already, and the chevron took the microphone's place while stretching filled the whole chat; there the
/// microphone stays and the panel keeps its height. Only an iPad: iPhone Duo unfolded is regular width too, and
/// keeps the upstream short panel that stretches.
public func chatMediaInputAllowsExpansion(widthClass: ContainerViewLayoutSizeClass?, deviceType: DeviceType?) -> Bool {
    return !(widthClass == .regular && deviceType == .tablet)
}

/// What Esc does in a chat, in order: cancel editing, then the reply, then the forward, then close the
/// sticker/emoji panel, then leave search, then message selection, then leave the chat.
public enum ChatEscapeAction: Equatable {
    case cancelEditing
    case cancelReply
    case cancelForward
    case closeMediaInput
    case closeSearch
    case cancelSelection
    case navigateBack
}

public struct ChatEscapeState: Equatable {
    public var isEditing: Bool
    public var hasReply: Bool
    public var hasForward: Bool
    public var isMediaInputOpen: Bool
    public var isSearchActive: Bool
    public var isSelecting: Bool
    public var canNavigateBack: Bool

    public init(isEditing: Bool = false, hasReply: Bool = false, hasForward: Bool = false, isMediaInputOpen: Bool = false, isSearchActive: Bool = false, isSelecting: Bool = false, canNavigateBack: Bool = true) {
        self.isEditing = isEditing
        self.hasReply = hasReply
        self.hasForward = hasForward
        self.isMediaInputOpen = isMediaInputOpen
        self.isSearchActive = isSearchActive
        self.isSelecting = isSelecting
        self.canNavigateBack = canNavigateBack
    }
}

/// The step Esc takes in a chat, or nil when there is nothing to do. Upstream's chat dropped the base
/// controller's Esc (back) when it overrode its key commands, so Esc did nothing in a chat.
public func chatEscapeAction(_ state: ChatEscapeState) -> ChatEscapeAction? {
    if state.isEditing {
        return .cancelEditing
    }
    if state.hasReply {
        return .cancelReply
    }
    if state.hasForward {
        return .cancelForward
    }
    if state.isMediaInputOpen {
        return .closeMediaInput
    }
    if state.isSearchActive {
        return .closeSearch
    }
    if state.isSelecting {
        return .cancelSelection
    }
    if state.canNavigateBack {
        return .navigateBack
    }
    return nil
}

/// Whether the open chat adds Esc to the window's key commands. Only on iPad (iPhone keeps upstream, where the
/// chat had no Esc of its own). The window keeps one command per key, and the chat's comes after the chat
/// list's, so while a text field outside the chat has the focus (the chat list's search field in split view) the
/// chat leaves Esc to that field's controller.
public func chatHandlesEscapeKey(deviceType: DeviceType?, firstResponderIsOutsideChat: Bool) -> Bool {
    return deviceType == .tablet && !firstResponderIsOutsideChat
}
