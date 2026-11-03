import XCTest
import QuartzCore
@testable import SemanticStatusNode

// The view-once voice message's countdown ring. It is fed a MediaPlayer status: a position, and the
// moment it was taken (`generationTimestamp`). A generation of 0 means "the clock is not running, show
// the position as is" (MediaPlayer stamps that on a first play, before the audio session is up, and on
// the loop at the end). Read as a real moment it counted the whole device uptime ahead: the ring was
// fully used up, the spark at a random angle, on every first play and every resume.
final class SemanticStatusNodeSecretTimeoutTests: XCTestCase {
    func testZeroGenerationDoesNotCountAhead() {
        let context = SemanticStatusNodeSecretTimeoutContext(position: 1.0, duration: 10.0, generationTimestamp: 0.0, appearance: nil)
        let state = context.drawingState(transitionFraction: 1.0) as! SemanticStatusNodeSecretTimeoutContext.DrawingState
        XCTAssertEqual(state.value, 0.1, accuracy: 0.0001)
    }

    func testZeroGenerationAfterAnUpdateDoesNotCountAhead() {
        let context = SemanticStatusNodeSecretTimeoutContext(position: 1.0, duration: 10.0, generationTimestamp: CACurrentMediaTime(), appearance: nil)
        context.updateValue(position: 4.0, duration: 10.0, generationTimestamp: 0.0)
        let state = context.drawingState(transitionFraction: 1.0) as! SemanticStatusNodeSecretTimeoutContext.DrawingState
        XCTAssertEqual(state.value, 0.4, accuracy: 0.0001)
    }

    func testRunningClockCountsAhead() {
        let generation = CACurrentMediaTime() - 2.0
        let context = SemanticStatusNodeSecretTimeoutContext(position: 1.0, duration: 10.0, generationTimestamp: generation, appearance: nil)
        let state = context.drawingState(transitionFraction: 1.0) as! SemanticStatusNodeSecretTimeoutContext.DrawingState
        // 1 s of position plus the ~2 s since the status was taken.
        XCTAssertEqual(state.value, 0.3, accuracy: 0.01)
    }
}
