import XCTest
import CallKit
@testable import TelegramCallsUI

// CallKit hands the app end and answer actions by call UUID. A stale or placeholder call (a VoIP push the
// app could not use, a call-back placeholder, an earlier call) must never act on the call that is current.
final class CallKitActionTargetTests: XCTestCase {
    func testActionForTheCurrentCallActsOnIt() {
        let current = UUID()
        XCTAssertEqual(callKitActionTarget(uuid: current, personalCallId: current, hasGroupCall: false), .personalCall)
    }

    func testEndActionForAnotherUUIDDoesNotTouchThePersonalCall() {
        XCTAssertEqual(callKitActionTarget(uuid: UUID(), personalCallId: UUID(), hasGroupCall: false), .none)
    }

    func testActionWithoutACurrentCallActsOnNothing() {
        XCTAssertEqual(callKitActionTarget(uuid: UUID(), personalCallId: nil, hasGroupCall: false), .none)
    }

    func testGroupCallKeepsTakingActionsThatAreNotForThePersonalCall() {
        XCTAssertEqual(callKitActionTarget(uuid: UUID(), personalCallId: nil, hasGroupCall: true), .groupCall)
        let personal = UUID()
        XCTAssertEqual(callKitActionTarget(uuid: personal, personalCallId: personal, hasGroupCall: true), .personalCall)
    }

    func testOnlyThePersonalCallAnswers() {
        let current = UUID()
        XCTAssertTrue(callKitActionAnswersPersonalCall(uuid: current, personalCallId: current))
        XCTAssertFalse(callKitActionAnswersPersonalCall(uuid: UUID(), personalCallId: current))
        XCTAssertFalse(callKitActionAnswersPersonalCall(uuid: current, personalCallId: nil))
    }

    func testMuteActionNamesTheCallNotTheAction() {
        let call = UUID()
        let action = CXSetMutedCallAction(call: call, muted: true)
        XCTAssertNotEqual(action.uuid, call, "the action's own id is not the call's")
        let target = callKitMuteTarget(action)
        XCTAssertEqual(target.callUUID, call)
        XCTAssertTrue(target.isMuted)
        XCTAssertFalse(callKitMuteTarget(CXSetMutedCallAction(call: call, muted: false)).isMuted)
    }

    /// After a 1:1 call turned into a conference the CallKit call stays, under the 1:1 call's id, but the app's current
    /// call is the conference. A mute from the lock screen must reach it.
    func testMuteReachesTheCallThatHoldsTheCallKitId() {
        let callKitCall = UUID()
        XCTAssertEqual(callKitMuteRecipient(uuid: callKitCall, personalCallId: callKitCall, conferenceSourceCallId: nil, groupCallConferenceSourceId: nil), .personalCall)
        XCTAssertEqual(callKitMuteRecipient(uuid: callKitCall, personalCallId: nil, conferenceSourceCallId: callKitCall, groupCallConferenceSourceId: nil), .conferenceSource)
        XCTAssertEqual(callKitMuteRecipient(uuid: callKitCall, personalCallId: nil, conferenceSourceCallId: nil, groupCallConferenceSourceId: callKitCall), .conference)
    }

    func testMuteForAnotherCallKitIdReachesNoCall() {
        let other = UUID()
        XCTAssertEqual(callKitMuteRecipient(uuid: UUID(), personalCallId: other, conferenceSourceCallId: other, groupCallConferenceSourceId: other), .none)
        XCTAssertEqual(callKitMuteRecipient(uuid: UUID(), personalCallId: nil, conferenceSourceCallId: nil, groupCallConferenceSourceId: nil), .none)
    }
}
