import XCTest
@testable import TelegramCallsUI

final class CallKitMuteSyncTests: XCTestCase {
    func testMutingInTheAppIsReportedOnce() {
        var sync = CallKitMuteSync()
        let call = UUID()
        XCTAssertTrue(sync.shouldReport(uuid: call, isMuted: true))
        XCTAssertFalse(sync.shouldReport(uuid: call, isMuted: true))
    }

    func testUnmutingAfterMutingIsReported() {
        var sync = CallKitMuteSync()
        let call = UUID()
        XCTAssertTrue(sync.shouldReport(uuid: call, isMuted: true))
        XCTAssertTrue(sync.shouldReport(uuid: call, isMuted: false))
    }

    func testACallStartsUnmutedSoUnmutedIsNotReported() {
        var sync = CallKitMuteSync()
        XCTAssertFalse(sync.shouldReport(uuid: UUID(), isMuted: false))
    }

    /// CallKit's own mute action reaches the app, which applies it and runs its normal mute path. That path must not send
    /// the action back to CallKit.
    func testAStateCallKitSetItselfIsNotReportedBack() {
        var sync = CallKitMuteSync()
        let call = UUID()
        sync.systemSet(uuid: call, isMuted: true)
        XCTAssertFalse(sync.shouldReport(uuid: call, isMuted: true))
        XCTAssertTrue(sync.shouldReport(uuid: call, isMuted: false))
    }

    func testCallsAreIndependentAndForgettingResetsToUnmuted() {
        var sync = CallKitMuteSync()
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(sync.shouldReport(uuid: first, isMuted: true))
        XCTAssertTrue(sync.shouldReport(uuid: second, isMuted: true))
        sync.forget(uuid: first)
        XCTAssertFalse(sync.shouldReport(uuid: first, isMuted: false))
        XCTAssertFalse(sync.shouldReport(uuid: second, isMuted: true))
        sync.forgetAll()
        XCTAssertFalse(sync.shouldReport(uuid: second, isMuted: false))
    }

    /// The app's own mute transaction comes back as a CallKit action. It is already applied, and applying it again could
    /// undo a newer tap that came in between.
    func testAnActionTheAppRequestedIsRecognisedOnce() {
        var sync = CallKitMuteSync()
        let action = UUID()
        sync.appRequested(actionId: action)
        XCTAssertTrue(sync.isAppRequested(actionId: action))
        XCTAssertFalse(sync.isAppRequested(actionId: action))
        XCTAssertFalse(sync.isAppRequested(actionId: UUID()))
    }

    func testAFailedReportRestoresWhatCallKitShows() {
        var sync = CallKitMuteSync()
        let call = UUID()
        let action = UUID()
        XCTAssertTrue(sync.shouldReport(uuid: call, isMuted: true))
        sync.appRequested(actionId: action)
        sync.appRequestFailed(actionId: action, uuid: call, previous: false)
        XCTAssertFalse(sync.isAppRequested(actionId: action))
        XCTAssertTrue(sync.shouldReport(uuid: call, isMuted: true), "CallKit still shows unmuted, so muting is reported again")
    }

    func testForgettingAllDropsPendingAppActions() {
        var sync = CallKitMuteSync()
        let action = UUID()
        sync.appRequested(actionId: action)
        sync.forgetAll()
        XCTAssertFalse(sync.isAppRequested(actionId: action))
    }
}
