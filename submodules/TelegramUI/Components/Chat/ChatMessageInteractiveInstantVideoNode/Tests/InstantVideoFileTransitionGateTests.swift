import XCTest
@testable import ChatMessageInteractiveInstantVideoNode

/// A round video in a bubble turns into a voice-style row while its transcription is shown and back when it collapses.
/// The expand animation hides the video and lets go of its player when it finishes (0.2 s). A collapse inside those
/// 0.2 s (a transcription that comes back empty, a quick second tap) ran before that completion, which then hid the
/// video again: the round video stayed an empty circle (owner's recording, 2026-11-07).
final class InstantVideoFileTransitionGateTests: XCTestCase {
    func testTheExpandCompletionAppliesWhenNothingFollowed() {
        var gate = InstantVideoFileTransitionGate()
        let expand = gate.begin()
        XCTAssertTrue(gate.isCurrent(expand))
    }

    func testACollapseBeforeTheExpandFinishesWins() {
        var gate = InstantVideoFileTransitionGate()
        let expand = gate.begin()
        let collapse = gate.begin()
        XCTAssertFalse(gate.isCurrent(expand), "the late expand completion must not hide the video again")
        XCTAssertTrue(gate.isCurrent(collapse))
    }

    func testOnlyTheLatestOfSeveralQuickTogglesApplies() {
        var gate = InstantVideoFileTransitionGate()
        let tokens = (0 ..< 5).map { _ in gate.begin() }
        XCTAssertEqual(tokens.filter { gate.isCurrent($0) }, [tokens[4]])
    }
}
