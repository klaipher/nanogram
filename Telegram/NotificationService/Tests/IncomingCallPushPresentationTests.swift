import XCTest
import UserNotifications
import CallKit
import Postbox
import TelegramCore
import NotificationsPresentationData
@testable import NotificationServiceExtensionLib

final class IncomingCallPushPresentationTests: XCTestCase {
    // CXProvider.reportNewIncomingVoIPPushPayload needs the notification filtering entitlement:
    // without it the call must become a notification, whatever the CallKit setting says.
    func testCallKitOnlyWithSystemIntegrationAndFiltering() {
        XCTAssertTrue(IncomingCallPushPresentation.reportsToCallKit(systemIntegrationEnabled: true, canFilterNotifications: true))
        XCTAssertFalse(IncomingCallPushPresentation.reportsToCallKit(systemIntegrationEnabled: true, canFilterNotifications: false))
        XCTAssertFalse(IncomingCallPushPresentation.reportsToCallKit(systemIntegrationEnabled: false, canFilterNotifications: true))
        XCTAssertFalse(IncomingCallPushPresentation.reportsToCallKit(systemIntegrationEnabled: false, canFilterNotifications: false))
    }

    func testAlertNamesTheCaller() {
        let alert = IncomingCallPushPresentation.alert(callerName: "Alice", incomingCallMessage: "is calling you")
        XCTAssertEqual(alert.title, "Alice")
        XCTAssertEqual(alert.body, "is calling you")
    }

    func testAlertWithoutCallerStillShows() {
        for name in [nil, ""] as [String?] {
            let alert = IncomingCallPushPresentation.alert(callerName: name, incomingCallMessage: "is calling you")
            XCTAssertNil(alert.title)
            XCTAssertEqual(alert.body, "Incoming Call")
        }
    }

    // Tapping opens the caller's chat on the account the call is for, where the ringing call shows.
    func testUserInfoOpensTheCallersChatOnTheRightAccount() {
        let userInfo = IncomingCallPushPresentation.userInfo(accountId: 42, peerId: 1234, fromUserId: 1234)
        XCTAssertEqual(userInfo["accountId"] as? String, "42")
        XCTAssertEqual(userInfo["peerId"] as? String, "1234")
        XCTAssertEqual(userInfo["from_id"] as? String, "1234")
        XCTAssertTrue(IncomingCallPushPresentation.isIncomingCall(userInfo: userInfo))
        XCTAssertFalse(ServicePushPresentation.isQuietPlaceholder(userInfo: userInfo))
    }

    func testMarker() {
        XCTAssertTrue(IncomingCallPushPresentation.isIncomingCall(userInfo: IncomingCallPushPresentation.markerUserInfo))
        XCTAssertFalse(IncomingCallPushPresentation.isIncomingCall(userInfo: ["p": "encrypted"]))
    }

    func testRingsWithTheRingtone() throws {
        guard #available(iOS 15.2, *) else {
            throw XCTSkip("no ringtone sound before iOS 15.2")
        }
        XCTAssertEqual(IncomingCallPushPresentation.sound, UNNotificationSound.defaultRingtone)
    }
    // CallKit refusing a call the user filtered (blocked caller, Do Not Disturb, restricted or
    // protected modes) or one it already shows must not turn into a ringing notification. Only a
    // failure to hand the call over at all (no entitlement, unknown) falls back to it.
    func testRingsOnlyWhenCallKitCouldNotTakeTheCall() {
        let refusals: [Int] = [
            CXErrorCodeIncomingCallError.Code.callUUIDAlreadyExists.rawValue,
            CXErrorCodeIncomingCallError.Code.filteredByDoNotDisturb.rawValue,
            CXErrorCodeIncomingCallError.Code.filteredByBlockList.rawValue,
            5, 6, 7, 99
        ]
        for code in refusals {
            let error = NSError(domain: CXErrorDomainIncomingCall, code: code)
            XCTAssertFalse(IncomingCallPushPresentation.ringsAfterCallKitError(error), "code \(code)")
        }
        for code in [CXErrorCodeIncomingCallError.Code.unknown.rawValue, CXErrorCodeIncomingCallError.Code.unentitled.rawValue] {
            let error = NSError(domain: CXErrorDomainIncomingCall, code: code)
            XCTAssertTrue(IncomingCallPushPresentation.ringsAfterCallKitError(error), "code \(code)")
        }
        XCTAssertTrue(IncomingCallPushPresentation.ringsAfterCallKitError(NSError(domain: "SomethingElse", code: 2)))
    }

    // MARK: - The ringing notification is made only to be shown

    private final class Flow {
        var events: [String] = []
        var reportCompletion: ((Error?) -> Void)?

        func present(reportsToCallKit: Bool) {
            IncomingCallPushPresentation.present(
                reportsToCallKit: reportsToCallKit,
                reportToCallKit: { completion in
                    self.events.append("report")
                    self.reportCompletion = completion
                },
                makeRingingContent: { (done: @escaping (String) -> Void) in
                    self.events.append("make")
                    done("ringing")
                },
                showRingingContent: { content in
                    self.events.append("show \(content)")
                },
                completed: {
                    self.events.append("completed")
                }
            )
        }
    }

    // When CallKit takes the call the banner (contact lookup, avatar drawing) is never made: the
    // call is handed over as fast as without it.
    func testCallKitTakesTheCallWithoutMakingTheBanner() {
        let flow = Flow()
        flow.present(reportsToCallKit: true)
        XCTAssertEqual(flow.events, ["report"])
        flow.reportCompletion?(nil)
        XCTAssertEqual(flow.events, ["report", "completed"])
    }

    func testCallKitRefusalMakesNoBanner() {
        let flow = Flow()
        flow.present(reportsToCallKit: true)
        flow.reportCompletion?(NSError(domain: CXErrorDomainIncomingCall, code: CXErrorCodeIncomingCallError.Code.filteredByDoNotDisturb.rawValue))
        XCTAssertEqual(flow.events, ["report", "completed"])
    }

    // CallKit could not take the call: the banner is made then, and rings.
    func testCallKitFailureMakesAndShowsTheBanner() {
        let flow = Flow()
        flow.present(reportsToCallKit: true)
        XCTAssertEqual(flow.events, ["report"])
        flow.reportCompletion?(NSError(domain: CXErrorDomainIncomingCall, code: CXErrorCodeIncomingCallError.Code.unentitled.rawValue))
        XCTAssertEqual(flow.events, ["report", "make", "show ringing", "completed"])
    }

    func testWithoutCallKitTheBannerRings() {
        let flow = Flow()
        flow.present(reportsToCallKit: false)
        XCTAssertEqual(flow.events, ["make", "show ringing", "completed"])
    }

    // MARK: - Routing, delivery, acknowledgement, cleanup

    private func route() -> IncomingCallNotificationRouting.Call {
        return IncomingCallNotificationRouting.Call(accountId: 42, peerId: 1234, fromId: 1234, callId: 777, accessHash: -5, updates: "AAAA", isVideo: true)
    }

    // The app injects the call from these keys: they are the ones of the VoIP push payload.
    func testUserInfoCarriesTheCallForTheApp() throws {
        let userInfo = IncomingCallPushPresentation.userInfo(accountId: 42, peerId: 1234, fromUserId: 1234, call: self.route())
        XCTAssertEqual(userInfo["call_id"] as? String, "777")
        XCTAssertEqual(userInfo["call_ah"] as? String, "-5")
        XCTAssertEqual(userInfo["updates"] as? String, "AAAA")
        XCTAssertEqual(userInfo["isVideo"] as? Bool, true)
        XCTAssertTrue(IncomingCallPushPresentation.isIncomingCall(userInfo: userInfo))
        XCTAssertEqual(IncomingCallNotificationRouting.call(userInfo: userInfo), self.route())
    }

    func testUserInfoWithoutACallRoutesNothing() {
        let userInfo = IncomingCallPushPresentation.userInfo(accountId: 42, peerId: 1234, fromUserId: 1234)
        XCTAssertNil(userInfo["call_id"])
        XCTAssertNil(IncomingCallNotificationRouting.call(userInfo: userInfo))
        XCTAssertNil(IncomingCallNotificationRouting.call(userInfo: ["call_id": "1"]))
    }

    func testCategoryOnlyForOneToOneCalls() {
        XCTAssertEqual(IncomingCallPushPresentation.categoryIdentifier(isGroupCall: false), "incomingCall")
        XCTAssertNil(IncomingCallPushPresentation.categoryIdentifier(isGroupCall: true))
        XCTAssertEqual(IncomingCallNotificationRouting.categoryIdentifier, "incomingCall")
        XCTAssertEqual(IncomingCallNotificationRouting.answerActionIdentifier, "incomingCall.answer")
        XCTAssertEqual(IncomingCallNotificationRouting.declineActionIdentifier, "incomingCall.decline")
    }

    func testThreadPerAccountAndCaller() {
        XCTAssertEqual(IncomingCallPushPresentation.threadIdentifier(accountId: 42, peerId: 1234), "nanogram.call.42.1234")
        XCTAssertNotEqual(IncomingCallPushPresentation.threadIdentifier(accountId: 43, peerId: 1234), IncomingCallPushPresentation.threadIdentifier(accountId: 42, peerId: 1234))
    }

    // A locked app and hidden names show no caller, as a message shows no sender.
    func testCallerNameIsHiddenWhenLockedOrNamesHidden() {
        XCTAssertEqual(IncomingCallPushPresentation.shownCallerName("Alice", isAppLocked: false, displayNameOnLockscreen: true), "Alice")
        XCTAssertNil(IncomingCallPushPresentation.shownCallerName("Alice", isAppLocked: true, displayNameOnLockscreen: true))
        XCTAssertNil(IncomingCallPushPresentation.shownCallerName("Alice", isAppLocked: false, displayNameOnLockscreen: false))
        XCTAssertNil(IncomingCallPushPresentation.shownCallerName(nil, isAppLocked: false, displayNameOnLockscreen: true))
        let alert = IncomingCallPushPresentation.alert(callerName: IncomingCallPushPresentation.shownCallerName("Alice", isAppLocked: true, displayNameOnLockscreen: true), incomingCallMessage: "is calling you")
        XCTAssertNil(alert.title)
        XCTAssertEqual(alert.body, "Incoming Call")
    }

    // Time Sensitive is set on the mutable content before the system updates it from the intent,
    // and has to survive that update.
    func testTimeSensitiveDelivery() {
        let content = UNMutableNotificationContent()
        IncomingCallPushPresentation.applyDelivery(to: content)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(content.relevanceScore, 1.0)
        let copy = content.mutableCopy() as? UNMutableNotificationContent
        XCTAssertEqual(copy?.interruptionLevel, .timeSensitive)
        XCTAssertEqual(copy?.relevanceScore, 1.0)
    }

    @available(iOS 15.0, *)
    func testTimeSensitiveSurvivesTheSystemUpdate() throws {
        let content = UNMutableNotificationContent()
        content.title = "Alice"
        content.body = "is calling you"
        IncomingCallPushPresentation.applyDelivery(to: content)
        let person = IncomingCallCommunication.anonymousPerson(name: "Alice")
        let intent = IncomingCallCommunication.intent(caller: person, callId: 1, isVideo: false, date: Date())
        let updated: UNNotificationContent
        do {
            updated = try content.updating(from: intent)
        } catch let error {
            throw XCTSkip("the test process cannot update content from an intent: \(error)")
        }
        XCTAssertEqual(updated.interruptionLevel, .timeSensitive)
        XCTAssertEqual(updated.relevanceScore, 1.0)
    }

    func testFallbackSoundIsABundledNamedSound() {
        XCTAssertEqual(IncomingCallPushPresentation.fallbackSoundName, "0.m4a")
        XCTAssertNotEqual(IncomingCallPushPresentation.fallbackSound, UNNotificationSound.default)
    }

    func testAcknowledgementHoldsTheRingBackForUnderASecond() {
        XCTAssertGreaterThan(IncomingCallPushPresentation.acknowledgementTimeout, 0.0)
        XCTAssertLessThanOrEqual(IncomingCallPushPresentation.acknowledgementTimeout, 1.0)
    }

    func testCompletionJoinRunsOnceAfterAllCompletions() {
        var runs = 0
        let join = IncomingCallPushPresentation.CompletionJoin(count: 2, action: { runs += 1 })
        join.complete()
        XCTAssertEqual(runs, 0)
        join.complete()
        XCTAssertEqual(runs, 1)
        join.complete()
        XCTAssertEqual(runs, 1)
    }

    private final class AcknowledgedFlow {
        var events: [String] = []
        var acknowledgeCompletion: ((IncomingCallProbeResult) -> Void)?
        var decisions: [IncomingCallPushPresentation.RingDecision] = []
        var shown: [String] = []
        var isRepeated = false

        func present(reportsToCallKit: Bool, reportError: Error? = nil) {
            IncomingCallPushPresentation.present(
                reportsToCallKit: reportsToCallKit,
                reportToCallKit: { completion in
                    self.events.append("report")
                    completion(reportError)
                },
                makeRingingContent: { (done: @escaping (String) -> Void) in
                    self.events.append("make")
                    done("ringing")
                },
                showRingingContent: { content in
                    self.events.append("show")
                    self.shown.append(content)
                },
                acknowledgeRing: { done in
                    self.events.append("acknowledge")
                    self.acknowledgeCompletion = done
                },
                isRepeatedCall: self.isRepeated,
                makeQuietContent: { _ in "quiet" },
                decided: { decision, _ in
                    self.decisions.append(decision)
                },
                startWatch: {
                    self.events.append("watch")
                },
                completed: {
                    self.events.append("completed")
                }
            )
        }
    }

    // A ring is acknowledged (the caller sees "Ringing") and the extension is not done until
    // the acknowledgement arrived or was cut off.
    func testRingIsHandedBackAfterTheAcknowledgement() {
        let flow = AcknowledgedFlow()
        flow.present(reportsToCallKit: false)
        XCTAssertEqual(flow.events, ["acknowledge", "make"])
        flow.acknowledgeCompletion?(.ringing)
        XCTAssertEqual(flow.events, ["acknowledge", "make", "show", "watch", "completed"])
        XCTAssertEqual(flow.shown, ["ringing"])
    }

    func testAcknowledgementFinishingFirstStillWaitsForTheBanner() {
        var events: [String] = []
        var madeContent: ((String) -> Void)?
        IncomingCallPushPresentation.present(
            reportsToCallKit: false,
            reportToCallKit: { _ in },
            makeRingingContent: { (done: @escaping (String) -> Void) in madeContent = done },
            showRingingContent: { _ in events.append("show") },
            acknowledgeRing: { done in
                events.append("acknowledged")
                done(.unknown)
            },
            completed: { events.append("completed") }
        )
        XCTAssertEqual(events, ["acknowledged"])
        madeContent?("ringing")
        XCTAssertEqual(events, ["acknowledged", "show", "completed"])
    }

    // A call CallKit takes is acknowledged by the app CallKit launches, not by the extension.
    func testCallKitTakingTheCallIsNotAcknowledgedHere() {
        let flow = AcknowledgedFlow()
        flow.present(reportsToCallKit: true)
        XCTAssertEqual(flow.events, ["report", "completed"])
    }

    func testCallKitFailureAcknowledgesTheRing() {
        let flow = AcknowledgedFlow()
        flow.present(reportsToCallKit: true, reportError: NSError(domain: CXErrorDomainIncomingCall, code: CXErrorCodeIncomingCallError.Code.unentitled.rawValue))
        XCTAssertEqual(flow.events, ["report", "acknowledge", "make"])
    }

    // A call the server already ended is not rung and no watch starts.
    func testEndedCallIsShownQuietlyWithoutAWatch() {
        let flow = AcknowledgedFlow()
        flow.present(reportsToCallKit: false)
        flow.acknowledgeCompletion?(.ended("rpc 400 CALL_ALREADY_DECLINED"))
        XCTAssertEqual(flow.events, ["acknowledge", "make", "show", "completed"])
        XCTAssertEqual(flow.shown, ["quiet"])
        XCTAssertEqual(flow.decisions, [.quiet])
    }

    // A slow or failed acknowledgement still rings: a missed call costs more than a ghost ring.
    func testUnknownAcknowledgementRingsAndWatches() {
        let flow = AcknowledgedFlow()
        flow.present(reportsToCallKit: false)
        flow.acknowledgeCompletion?(.unknown)
        XCTAssertEqual(flow.shown, ["ringing"])
        XCTAssertEqual(flow.decisions, [.ring])
        XCTAssertTrue(flow.events.contains("watch"))
    }

    // A repeated push of a call that already rings must not ring twice.
    func testRepeatedCallIsShownQuietly() {
        let flow = AcknowledgedFlow()
        flow.isRepeated = true
        flow.present(reportsToCallKit: false)
        flow.acknowledgeCompletion?(.ringing)
        XCTAssertEqual(flow.shown, ["quiet"])
        XCTAssertFalse(flow.events.contains("watch"))
    }

    // CallKit rings and ends the call itself: the watch belongs to the notification branch only.
    func testCallKitBranchNeverStartsAWatch() {
        let flow = AcknowledgedFlow()
        flow.present(reportsToCallKit: true)
        XCTAssertFalse(flow.events.contains("watch"))
    }

    func testRingDecision() {
        XCTAssertEqual(IncomingCallPushPresentation.ringDecision(acknowledgement: .ringing), .ring)
        XCTAssertEqual(IncomingCallPushPresentation.ringDecision(acknowledgement: .unknown), .ring)
        XCTAssertEqual(IncomingCallPushPresentation.ringDecision(acknowledgement: .ended("x")), .quiet)
    }

    func testQuietedContentHasNoSoundOrButtons() {
        let content = UNMutableNotificationContent()
        content.title = "Alice"
        content.sound = .defaultRingtone
        content.categoryIdentifier = IncomingCallNotificationRouting.categoryIdentifier
        content.interruptionLevel = .timeSensitive
        content.userInfo = IncomingCallPushPresentation.userInfo(accountId: 1, peerId: 2, fromUserId: 2)
        let quiet = IncomingCallPushPresentation.quieted(content)
        XCTAssertNil(quiet.sound)
        XCTAssertEqual(quiet.categoryIdentifier, "")
        XCTAssertEqual(quiet.interruptionLevel, .passive)
        XCTAssertEqual(quiet.title, "Alice")
        XCTAssertTrue(IncomingCallPushPresentation.isQuietCall(userInfo: quiet.userInfo))
        XCTAssertTrue(ServicePushPresentation.isQuietPlaceholder(userInfo: quiet.userInfo))
        XCTAssertFalse(IncomingCallPushPresentation.isIncomingCall(userInfo: quiet.userInfo))
    }

    func testQuietCallIsTakenDownAfterDelivery() {
        let content = UNMutableNotificationContent()
        content.title = "Alice"
        content.sound = .defaultRingtone
        content.userInfo = IncomingCallPushPresentation.quietUserInfo
        for canFilter in [false, true] {
            let result = ServicePushPresentation.presentation(generated: content, initialContent: nil, canFilter: canFilter)
            XCTAssertTrue(result.isQuietPlaceholder)
            XCTAssertNil(result.content.sound)
        }
    }

    func testCallKitResultDescription() {
        XCTAssertEqual(IncomingCallPushPresentation.callKitResultDescription(nil), "none")
        let description = IncomingCallPushPresentation.callKitResultDescription(NSError(domain: CXErrorDomainIncomingCall, code: CXErrorCodeIncomingCallError.Code.unentitled.rawValue))
        XCTAssertTrue(description.contains(CXErrorDomainIncomingCall))
        XCTAssertTrue(description.contains("code: \(CXErrorCodeIncomingCallError.Code.unentitled.rawValue)"))
    }

    func testInterruptionLevelNames() {
        XCTAssertEqual(IncomingCallPushPresentation.interruptionLevelName(.timeSensitive), "timeSensitive")
        XCTAssertEqual(IncomingCallPushPresentation.interruptionLevelName(.active), "active")
        XCTAssertEqual(IncomingCallPushPresentation.interruptionLevelName(.passive), "passive")
    }

    // The ring for a caller goes when that caller's call ended: the phone-call service message.
    func testPhoneCallServiceMessageEndsTheRing() {
        let call = TelegramMediaAction(action: .phoneCall(callId: 777, discardReason: .missed, duration: nil, isVideo: false))
        XCTAssertTrue(IncomingCallPushPresentation.isPhoneCallServiceMessage(media: [call]))
        let other = TelegramMediaAction(action: .historyCleared)
        XCTAssertFalse(IncomingCallPushPresentation.isPhoneCallServiceMessage(media: [other]))
        XCTAssertFalse(IncomingCallPushPresentation.isPhoneCallServiceMessage(media: []))
        XCTAssertEqual(IncomingCallPushPresentation.phoneCallServiceMessageCallId(media: [call]), 777)
        XCTAssertNil(IncomingCallPushPresentation.phoneCallServiceMessageCallId(media: [other]))
    }
}
