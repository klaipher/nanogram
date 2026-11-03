import XCTest
import UniversalMediaPlayer
@testable import AudioWaveformComponent

// An unlistened incoming voice message draws its whole waveform in the colour of the played part.
// When it plays, the bubble drops that only after the message is marked listened and the bubble lays
// itself out again; until then the waveform looked "all filled" with no visible progress.
final class AudioWaveformUnplayedHighlightTests: XCTestCase {
    func testHighlightIsDroppedWhenTheMessageStartsPlaying() {
        var highlight = AudioWaveformUnplayedHighlight()
        highlight.update(requested: true, contentChanged: true)
        // The message's status before it is played.
        highlight.update(status: .paused)
        XCTAssertTrue(highlight.isDrawn)

        // First play: the bubble has not laid out again yet, so the highlight is still requested.
        highlight.update(status: .buffering(initial: true, whilePlaying: true, progress: 0.0, display: true))
        XCTAssertTrue(highlight.isDrawn)
        highlight.update(status: .playing)
        highlight.update(requested: true, contentChanged: false)
        XCTAssertFalse(highlight.isDrawn)

        // Pausing does not bring it back.
        highlight.update(status: .paused)
        XCTAssertFalse(highlight.isDrawn)
    }

    func testListenedMessageIsNeverHighlighted() {
        var highlight = AudioWaveformUnplayedHighlight()
        highlight.update(requested: false, contentChanged: true)
        XCTAssertFalse(highlight.isDrawn)
        highlight.update(status: .playing)
        XCTAssertFalse(highlight.isDrawn)
    }

    func testANewUnlistenedMessageIsHighlightedAgain() {
        var highlight = AudioWaveformUnplayedHighlight()
        highlight.update(requested: true, contentChanged: true)
        highlight.update(status: .playing)
        XCTAssertFalse(highlight.isDrawn)

        // The view now shows another unlistened message.
        highlight.update(requested: true, contentChanged: true)
        XCTAssertTrue(highlight.isDrawn)

        // Or the same view went through a listened message first.
        highlight.update(status: .playing)
        highlight.update(requested: false, contentChanged: false)
        highlight.update(requested: true, contentChanged: false)
        XCTAssertTrue(highlight.isDrawn)
    }
}
