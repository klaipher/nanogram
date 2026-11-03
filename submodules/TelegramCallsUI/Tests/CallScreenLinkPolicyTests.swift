import Foundation
import CoreGraphics
import XCTest
@testable import TelegramCallsUI
import CallScreen

/// The call screen's display links. They used to run for as long as the view was on screen, at 60 or 120 Hz for
/// the audio-level smoothing and 30 Hz for the background and the blobs, even when nothing moved.
final class CallScreenLinkPolicyTests: XCTestCase {
    func testAudioLevelLinkRunsOnlyWhileTheLevelMoves() {
        XCTAssertFalse(CallScreenLinkPolicy.audioLevelNeedsLink(audioLevel: 0.0, target: 0.0, bump: 0.0))
        XCTAssertTrue(CallScreenLinkPolicy.audioLevelNeedsLink(audioLevel: 0.5, target: 0.0, bump: 0.0))
        XCTAssertTrue(CallScreenLinkPolicy.audioLevelNeedsLink(audioLevel: 0.0, target: 0.3, bump: 0.0))
        XCTAssertTrue(CallScreenLinkPolicy.audioLevelNeedsLink(audioLevel: 0.0, target: 0.0, bump: 2.0))
    }

    func testAttenuationKeepsTheSameDecayPerSecondAtAnyFrameRate() {
        // The old step was fixed at 0.8 per 60 Hz frame.
        let at60 = CallScreenLinkPolicy.attenuationKeep(deltaTime: 1.0 / 60.0)
        XCTAssertEqual(at60, 0.8, accuracy: 0.0001)
        let at30 = CallScreenLinkPolicy.attenuationKeep(deltaTime: 1.0 / 30.0)
        XCTAssertEqual(at30, 0.64, accuracy: 0.0001)
        let at120 = CallScreenLinkPolicy.attenuationKeep(deltaTime: 1.0 / 120.0)
        XCTAssertEqual(at120 * at120, 0.8, accuracy: 0.0001)
        // A stalled frame never overshoots.
        let stalled = CallScreenLinkPolicy.attenuationKeep(deltaTime: 5.0)
        XCTAssertTrue(stalled >= 0.0 && stalled < 0.01)
        XCTAssertEqual(CallScreenLinkPolicy.attenuationKeep(deltaTime: 0.0), 1.0, accuracy: 0.0001)
    }

    func testIdenticalScaleWritesAreSkipped() {
        XCTAssertFalse(CallScreenLinkPolicy.shouldWriteScale(previous: 1.0, new: 1.0))
        XCTAssertFalse(CallScreenLinkPolicy.shouldWriteScale(previous: 1.0, new: 1.0003))
        XCTAssertTrue(CallScreenLinkPolicy.shouldWriteScale(previous: 1.0, new: 1.01))
        XCTAssertTrue(CallScreenLinkPolicy.shouldWriteScale(previous: 1.2, new: 1.0))
    }

    func testBackgroundLinkRunsInEnergySavingOnlyWhileAnimationsRun() {
        XCTAssertTrue(CallScreenLinkPolicy.backgroundNeedsLink(isInHierarchy: true, isEnergySaving: false, hasRunningAnimation: false))
        XCTAssertFalse(CallScreenLinkPolicy.backgroundNeedsLink(isInHierarchy: true, isEnergySaving: true, hasRunningAnimation: false))
        XCTAssertTrue(CallScreenLinkPolicy.backgroundNeedsLink(isInHierarchy: true, isEnergySaving: true, hasRunningAnimation: true))
        XCTAssertFalse(CallScreenLinkPolicy.backgroundNeedsLink(isInHierarchy: false, isEnergySaving: false, hasRunningAnimation: true))
    }

    func testBlobLinkRunsOnlyWhileTheBlobIsShown() {
        XCTAssertTrue(CallScreenLinkPolicy.blobsNeedLink(isInHierarchy: true, isShown: true))
        XCTAssertFalse(CallScreenLinkPolicy.blobsNeedLink(isInHierarchy: true, isShown: false))
        XCTAssertFalse(CallScreenLinkPolicy.blobsNeedLink(isInHierarchy: false, isShown: true))
    }

    func testEnergySavingFollowsTheLiveSettings() {
        XCTAssertTrue(CallScreenLinkPolicy.isEnergySaving(fullTranslucency: false))
        XCTAssertFalse(CallScreenLinkPolicy.isEnergySaving(fullTranslucency: true))
    }
}
