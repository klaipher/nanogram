import XCTest
import UserNotifications
import NotificationsPresentationData
@testable import NotificationServiceExtensionLib

final class IncomingCallResponseTests: XCTestCase {
    private let call = IncomingCallNotificationRouting.Call(accountId: 7, peerId: 100, fromId: 100, callId: 55, accessHash: 99, updates: "YWJj", isVideo: false)

    private var extensionRing: [AnyHashable: Any] {
        return IncomingCallPushPresentation.userInfo(accountId: 7, peerId: 100, fromUserId: 100, call: self.call)
    }

    func testTapAnswerAndDeclineCarryTheCall() {
        XCTAssertEqual(IncomingCallResponse.plan(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: self.extensionRing), IncomingCallResponse.Plan(kind: .open, call: self.call))
        XCTAssertEqual(IncomingCallResponse.plan(actionIdentifier: IncomingCallNotificationRouting.answerActionIdentifier, userInfo: self.extensionRing), IncomingCallResponse.Plan(kind: .answer, call: self.call))
        XCTAssertEqual(IncomingCallResponse.plan(actionIdentifier: IncomingCallNotificationRouting.declineActionIdentifier, userInfo: self.extensionRing), IncomingCallResponse.Plan(kind: .decline, call: self.call))
    }

    func testAnotherActionOrANonCallNotificationHasNoPlan() {
        XCTAssertNil(IncomingCallResponse.plan(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: self.extensionRing))
        XCTAssertNil(IncomingCallResponse.plan(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["peerId": "100"]))
    }

    func testARingWithoutTheCallStillPlansTheActionForTheAppsCurrentCall() {
        let userInfo = IncomingCallResponse.localRingUserInfo(peerId: 100)
        XCTAssertEqual(IncomingCallResponse.plan(actionIdentifier: IncomingCallNotificationRouting.declineActionIdentifier, userInfo: userInfo), IncomingCallResponse.Plan(kind: .decline, call: nil))
        let withoutUpdates = IncomingCallPushPresentation.userInfo(accountId: 7, peerId: 100, fromUserId: 100)
        XCTAssertEqual(IncomingCallResponse.plan(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: withoutUpdates), IncomingCallResponse.Plan(kind: .open, call: nil))
    }

    func testCallerFallbackNamesTheChat() {
        XCTAssertEqual(IncomingCallResponse.caller(userInfo: self.extensionRing)?.peerId, 100)
        XCTAssertEqual(IncomingCallResponse.caller(userInfo: self.extensionRing)?.accountId, 7)
        XCTAssertNil(IncomingCallResponse.caller(userInfo: IncomingCallResponse.localRingUserInfo(peerId: 100))?.accountId)
        XCTAssertNil(IncomingCallResponse.caller(userInfo: ["peerId": "100"]))
    }

    func testUpdatesDecodeFromBase64URLWithoutPadding() {
        XCTAssertEqual(IncomingCallResponse.updatesData("YWJj"), Data("abc".utf8))
        XCTAssertEqual(IncomingCallResponse.updatesData("-_8"), Data([0xfb, 0xff]))
        XCTAssertNil(IncomingCallResponse.updatesData("!!!"))
    }

    func testTheAppsOwnRingIsMarkedAsACallAndFoundByTheCleanupRule() {
        let userInfo = IncomingCallResponse.localRingUserInfo(peerId: 100)
        XCTAssertTrue(IncomingCallNotifications.isIncomingCall(userInfo: userInfo))
        XCTAssertTrue(IncomingCallResponse.isLocalRing(userInfo: userInfo))
        XCTAssertFalse(IncomingCallResponse.isLocalRing(userInfo: self.extensionRing))
        XCTAssertEqual(IncomingCallNotifications.identifiers(delivered: [("call_x", userInfo), ("other", ["peerId": "100"])], peerId: 100), ["call_x"])
        let old = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(IncomingCallNotifications.staleIdentifiers(delivered: [("call_x", userInfo, old)], now: old.addingTimeInterval(120)), ["call_x"])
    }

    func testForegroundTheAppsOwnRingPlaysItsSoundWithoutABanner() {
        let local = IncomingCallResponse.localRingUserInfo(peerId: 100)
        XCTAssertEqual(IncomingCallResponse.foregroundOptions(userInfo: local, showsBanner: false), [.sound, .list])
        XCTAssertEqual(IncomingCallResponse.foregroundOptions(userInfo: self.extensionRing, showsBanner: false), [])
        XCTAssertEqual(IncomingCallResponse.foregroundOptions(userInfo: self.extensionRing, showsBanner: true), [.banner, .list])
    }
}
