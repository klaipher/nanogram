import Foundation

/// What a chat message's animation is.
public enum StickerPlaybackKind: Equatable {
    /// A sticker (TGS, WebP, WebM): follows the "Loop Animated Stickers" energy setting.
    case sticker
    /// A custom emoji sent large: always loops.
    case customEmoji
    /// A standard animated emoji: shows its last frame, plays once on demand.
    case animatedEmoji
}

public enum StickerPlaybackDecision: Equatable {
    case loop
    case once
    case stillEnd
}

/// How a message's animation plays given the current `loopStickers` energy setting.
public func stickerPlaybackDecision(kind: StickerPlaybackKind, loopStickers: Bool) -> StickerPlaybackDecision {
    switch kind {
    case .sticker:
        return loopStickers ? .loop : .once
    case .customEmoji:
        return .loop
    case .animatedEmoji:
        return .stillEnd
    }
}

public enum StickerLoopChangeAction: Equatable {
    case none
    /// Loop from now on; the animation is still running, so only the mode changes.
    case switchToLoop
    /// Loop from now on and start it again: it had stopped at its end.
    case resumeLooping
    /// Play once from now on: the current loop finishes, then it stops.
    case switchToOnce
}

/// What a visible, set-up animation does when `loopStickers` changes after its setup.
public func stickerLoopChangeAction(kind: StickerPlaybackKind, loopStickers: Bool, currentlyLooping: Bool, isPlaying: Bool) -> StickerLoopChangeAction {
    guard kind == .sticker else {
        return .none
    }
    switch (currentlyLooping, stickerPlaybackDecision(kind: kind, loopStickers: loopStickers)) {
    case (false, .loop):
        return isPlaying ? .switchToLoop : .resumeLooping
    case (true, .once):
        return .switchToOnce
    default:
        return .none
    }
}
