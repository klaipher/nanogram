import XCTest
@testable import tgwatch_Watch_App

/// WATCH-API-1: haptics for record start and stop; Double Tap shortcuts are declared in the views.
final class CoreRecordFeedbackTests: XCTestCase {
    private let draft = VoiceRecordingDraft(fileURL: URL(fileURLWithPath: "/tmp/a.ogg"), duration: 3, waveform: Data())

    func testStartingARecordingGivesTheStartHaptic() {
        XCTAssertEqual(RecordHaptic.forTransition(from: .idle, to: .recording(elapsed: 0, level: 0)), .start)
        XCTAssertEqual(RecordHaptic.forTransition(from: .requestingPermission, to: .recording(elapsed: 0, level: 0)), .start)
    }

    func testStoppingGivesTheStopHaptic() {
        let rec = RecordState.recording(elapsed: 2, level: 0.3)
        XCTAssertEqual(RecordHaptic.forTransition(from: rec, to: .stopping), .stop)
        XCTAssertEqual(RecordHaptic.forTransition(from: rec, to: .review(draft)), .stop)
        XCTAssertEqual(RecordHaptic.forTransition(from: rec, to: .idle), .stop, "cancelled")
        XCTAssertEqual(RecordHaptic.forTransition(from: rec, to: .failed("x")), .stop)
    }

    func testLevelAndElapsedTicksAreSilent() {
        XCTAssertNil(RecordHaptic.forTransition(
            from: .recording(elapsed: 1, level: 0.1), to: .recording(elapsed: 1.1, level: 0.5)))
    }

    func testOtherTransitionsAreSilent() {
        XCTAssertNil(RecordHaptic.forTransition(from: .stopping, to: .review(draft)))
        XCTAssertNil(RecordHaptic.forTransition(from: .review(draft), to: .idle))
        XCTAssertNil(RecordHaptic.forTransition(from: .idle, to: .requestingPermission))
        XCTAssertNil(RecordHaptic.forTransition(from: .idle, to: .failed("denied")))
    }

    /// Double Tap triggers the primary button of a screen; each recorder screen declares exactly one
    /// (idle: start, recording: stop, review: send) and each video player one (replay).
    func testDoubleTapShortcutsAreDeclaredWhereTheSpecAsksForThem() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tgwatch Watch App/Messages")
        func count(_ file: String) throws -> Int {
            try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: ".handGestureShortcut(.primaryAction)").count - 1
        }
        XCTAssertEqual(try count("VoiceRecordView.swift"), 3)
        XCTAssertEqual(try count("VideoPlayerView.swift"), 1)
        XCTAssertEqual(try count("VideoNotePlayerView.swift"), 1)
    }
}
