import XCTest
@testable import StickerPlaybackPolicy

final class StickerPlaybackPolicyTests: XCTestCase {
    func test_sticker_loopsWhenLoopStickersIsOn_elseOnce() {
        XCTAssertEqual(stickerPlaybackDecision(kind: .sticker, loopStickers: true), .loop)
        XCTAssertEqual(stickerPlaybackDecision(kind: .sticker, loopStickers: false), .once)
    }

    func test_customEmoji_alwaysLoops() {
        XCTAssertEqual(stickerPlaybackDecision(kind: .customEmoji, loopStickers: true), .loop)
        XCTAssertEqual(stickerPlaybackDecision(kind: .customEmoji, loopStickers: false), .loop)
    }

    func test_animatedEmoji_alwaysStillAtEnd() {
        XCTAssertEqual(stickerPlaybackDecision(kind: .animatedEmoji, loopStickers: true), .stillEnd)
        XCTAssertEqual(stickerPlaybackDecision(kind: .animatedEmoji, loopStickers: false), .stillEnd)
    }

    func test_onceToLoop_whileStopped_resumesLooping() {
        XCTAssertEqual(stickerLoopChangeAction(kind: .sticker, loopStickers: true, currentlyLooping: false, isPlaying: false), .resumeLooping)
    }

    func test_onceToLoop_whileStillPlaying_justSwitchesMode() {
        XCTAssertEqual(stickerLoopChangeAction(kind: .sticker, loopStickers: true, currentlyLooping: false, isPlaying: true), .switchToLoop)
    }

    func test_loopToOnce_finishesTheCurrentLoop() {
        XCTAssertEqual(stickerLoopChangeAction(kind: .sticker, loopStickers: false, currentlyLooping: true, isPlaying: true), .switchToOnce)
    }

    func test_loopToOnce_whenNotPlaying_justSwitchesMode() {
        XCTAssertEqual(stickerLoopChangeAction(kind: .sticker, loopStickers: false, currentlyLooping: true, isPlaying: false), .switchToOnce)
    }

    func test_noChange_doesNothing() {
        XCTAssertEqual(stickerLoopChangeAction(kind: .sticker, loopStickers: true, currentlyLooping: true, isPlaying: true), .none)
        XCTAssertEqual(stickerLoopChangeAction(kind: .sticker, loopStickers: false, currentlyLooping: false, isPlaying: false), .none)
    }

    func test_otherKinds_neverChange() {
        for kind in [StickerPlaybackKind.customEmoji, .animatedEmoji] {
            for loop in [true, false] {
                for looping in [true, false] {
                    XCTAssertEqual(stickerLoopChangeAction(kind: kind, loopStickers: loop, currentlyLooping: looping, isPlaying: false), .none)
                }
            }
        }
    }
}
