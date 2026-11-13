import XCTest
import Intents
import UserNotifications
import NotificationsPresentationData
@testable import NotificationServiceExtensionLib

/// The ringing call notification is a communication notification for a call (INStartCallIntent),
/// so iOS draws the caller's photo on it, as it does the sender's on a message.
final class IncomingCallCommunicationTests: XCTestCase {
    override func setUpWithError() throws {
        guard #available(iOS 15.0, *) else {
            throw XCTSkip("communication notifications need iOS 15")
        }
    }

    // MARK: - Who calls

    // The system draws the title from the caller's name and hides the subtitle, so the name the
    // banner shows today (with the account it was delivered to) is the one it is drawn with.
    @available(iOS 15.0, *)
    func testCallerIsDrawnWithTheBannersTitle() throws {
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "Alice", recipientAccountName: "peter", contactIdentifier: "C-1"))
        let names = NotificationNames(title: "Alice", senderName: nil, silent: false, recipientAccountName: "peter")
        XCTAssertEqual(caller.displayedName, names.title)
        XCTAssertEqual(caller.displayedName, "Alice → peter")
        // Siri and Focus suggestions learn the caller alone.
        XCTAssertEqual(caller.donatedName, "Alice")
        XCTAssertEqual(caller.peerId, 1234)
        XCTAssertEqual(caller.contactIdentifier, "C-1")
    }

    @available(iOS 15.0, *)
    func testCallerWithOneAccount() throws {
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
        XCTAssertEqual(caller.displayedName, "Alice")
        XCTAssertEqual(caller.donatedName, "Alice")
    }

    // A call without a name keeps the "Incoming Call" banner as it is.
    @available(iOS 15.0, *)
    func testNoCallerWithoutAName() {
        XCTAssertNil(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: nil, recipientAccountName: "peter", contactIdentifier: nil))
        XCTAssertNil(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "", recipientAccountName: "peter", contactIdentifier: nil))
    }

    // The app's "call back" handler (AppDelegate, INStartCallIntent user activity) reads the
    // handle as the account the call came to and the caller, and calls from that account.
    @available(iOS 15.0, *)
    func testPersonCarriesTheAccountThePeerIdAndThePhoto() throws {
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "Alice", recipientAccountName: "peter", contactIdentifier: "C-1"))
        let image = INImage(imageData: Data([0x1]))
        let person = IncomingCallCommunication.person(caller, name: caller.displayedName, image: image)
        XCTAssertEqual(person.displayName, "Alice → peter")
        XCTAssertEqual(person.personHandle?.type, .unknown)
        let expected = IncomingCallNotifications.CallBack(accountId: 42, peerId: 1234)
        XCTAssertEqual(person.personHandle?.value.flatMap(IncomingCallNotifications.callBack(identifier:)), expected)
        XCTAssertEqual(person.customIdentifier.flatMap(IncomingCallNotifications.callBack(identifier:)), expected)
        XCTAssertEqual(person.contactIdentifier, "C-1")
        // INPerson keeps a copy of the image.
        XCTAssertNotNil(person.image)
        XCTAssertNil(IncomingCallCommunication.person(caller, name: caller.displayedName, image: nil).image)
        XCTAssertFalse(person.isMe)
    }

    // MARK: - Whether the caller is drawn

    // With the passcode lock on, a message names no sender and shows no face; the call banner stays
    // the plain "<caller> / is calling you" one: no photo, and nothing donated to the system.
    @available(iOS 15.0, *)
    func testLockedAppDrawsNoCaller() {
        XCTAssertTrue(IncomingCallCommunication.drawsCaller(isAppLocked: false, displayNameOnLockscreen: true, isGroupCall: false))
        XCTAssertFalse(IncomingCallCommunication.drawsCaller(isAppLocked: true, displayNameOnLockscreen: true, isGroupCall: false))
    }

    // With names hidden on the lock screen a message is not a communication notification (no
    // sender, nothing donated); the call keeps the plain banner too: no person, so no device
    // contact and no interaction handed to the system.
    @available(iOS 15.0, *)
    func testHiddenNamesDrawNoCaller() {
        XCTAssertFalse(IncomingCallCommunication.drawsCaller(isAppLocked: false, displayNameOnLockscreen: false, isGroupCall: false))
        XCTAssertFalse(IncomingCallCommunication.drawsCaller(isAppLocked: true, displayNameOnLockscreen: false, isGroupCall: false))
    }

    // A group call invite is no call to the inviter: calling them back (the donated intent's
    // "call back") would place a 1:1 call. Its banner stays the plain one, with nothing donated.
    @available(iOS 15.0, *)
    func testGroupCallsDrawNoCaller() {
        XCTAssertFalse(IncomingCallCommunication.drawsCaller(isAppLocked: false, displayNameOnLockscreen: true, isGroupCall: true))
    }

    // Privacy and Security ▸ Voice Calls ▸ Show Calls in Phone Recents, off: the call is still drawn
    // as the caller's, but nothing is donated, so Siri does not suggest it.
    @available(iOS 15.0, *)
    func testCallsHiddenFromRecentsAreNotDonated() {
        XCTAssertTrue(IncomingCallCommunication.donatesCall(showCallsInRecents: true))
        XCTAssertFalse(IncomingCallCommunication.donatesCall(showCallsInRecents: false))
    }

    // MARK: - Which picture

    @available(iOS 15.0, *)
    func testAvatarSource() {
        // The caller's photo, or their letters when it is not downloaded (peerAvatar decides).
        XCTAssertEqual(IncomingCallCommunication.avatarSource(displayNameOnLockscreen: true, hasCallerPeer: true, callerName: "Alice Smith"), .peer)
        // No stored peer (a conference invite from someone the account has not seen): letters of
        // the name the push carries.
        XCTAssertEqual(IncomingCallCommunication.avatarSource(displayNameOnLockscreen: true, hasCallerPeer: false, callerName: "Alice Smith"), .letters(["A", "S"]))
        XCTAssertEqual(IncomingCallCommunication.avatarSource(displayNameOnLockscreen: true, hasCallerPeer: false, callerName: nil), .none)
        // Names off on the lock screen: no face either, as for messages.
        XCTAssertEqual(IncomingCallCommunication.avatarSource(displayNameOnLockscreen: false, hasCallerPeer: true, callerName: "Alice"), .none)
        XCTAssertEqual(IncomingCallCommunication.avatarSource(displayNameOnLockscreen: false, hasCallerPeer: false, callerName: "Alice"), .none)
    }

    @available(iOS 15.0, *)
    func testLetters() {
        XCTAssertEqual(IncomingCallCommunication.letters(title: "Alice"), ["A"])
        XCTAssertEqual(IncomingCallCommunication.letters(title: "alice  bob smith "), ["A", "S"])
        XCTAssertEqual(IncomingCallCommunication.letters(title: "  "), [])
        XCTAssertEqual(IncomingCallCommunication.letters(title: "Ёлка Пальма"), ["Ё", "П"])
    }

    // MARK: - The intent

    @available(iOS 15.0, *)
    func testIntentRingsAnIncomingAudioCall() throws {
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
        let person = IncomingCallCommunication.person(caller, name: caller.displayedName, image: nil)
        let date = Date(timeIntervalSince1970: 1000)
        let intent = IncomingCallCommunication.intent(caller: person, callId: 777, isVideo: false, date: date)
        // Only a normal destination makes the ringtone ring (UNNotificationSound.defaultRingtone).
        XCTAssertEqual(intent.destinationType, .normal)
        XCTAssertEqual(intent.callCapability, .audioCall)
        XCTAssertEqual(intent.contacts?.map(\.displayName), ["Alice"])
        let record = try XCTUnwrap(intent.callRecordToCallBack)
        XCTAssertEqual(record.identifier, "777")
        XCTAssertEqual(record.callRecordType, .ringing)
        XCTAssertEqual(record.callCapability, .audioCall)
        XCTAssertEqual(record.dateCreated, date)
        XCTAssertEqual(record.participants?.map(\.displayName), ["Alice"])
    }

    @available(iOS 15.0, *)
    func testIntentForAVideoCall() throws {
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
        let person = IncomingCallCommunication.person(caller, name: caller.displayedName, image: nil)
        let intent = IncomingCallCommunication.intent(caller: person, callId: nil, isVideo: true, date: Date())
        XCTAssertEqual(intent.callCapability, .videoCall)
        XCTAssertEqual(intent.callRecordToCallBack?.callCapability, .videoCall)
        XCTAssertEqual(intent.destinationType, .normal)
    }

    // MARK: - Never lose the call

    private enum UpdateFailure: Error {
        case refused
    }

    private func ringingContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Alice"
        content.body = "is calling you"
        content.threadIdentifier = "1234"
        content.categoryIdentifier = "c"
        content.userInfo = IncomingCallPushPresentation.userInfo(accountId: 42, peerId: 1234, fromUserId: 1234)
        if #available(iOS 15.2, *) {
            content.sound = .defaultRingtone
        }
        return content
    }

    @available(iOS 15.0, *)
    func testAFailedUpdateKeepsTheBanner() throws {
        let content = self.ringingContent()
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
        let intent = IncomingCallCommunication.intent(caller: IncomingCallCommunication.person(caller, name: "Alice", image: nil), callId: 1, isVideo: false, date: Date())
        let result = IncomingCallCommunication.updatedContent(content, intent: intent, update: { _, _ in
            throw UpdateFailure.refused
        })
        XCTAssertTrue(result === content)
        XCTAssertEqual(result.title, "Alice")
        XCTAssertEqual(result.body, "is calling you")
        XCTAssertTrue(IncomingCallPushPresentation.isIncomingCall(userInfo: result.userInfo))
    }

    @available(iOS 15.0, *)
    func testUpdateHandsTheIntentToTheSystem() throws {
        let content = self.ringingContent()
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
        let intent = IncomingCallCommunication.intent(caller: IncomingCallCommunication.person(caller, name: "Alice", image: nil), callId: 1, isVideo: false, date: Date())
        let updated = UNMutableNotificationContent()
        var received: INStartCallIntent?
        let result = IncomingCallCommunication.updatedContent(content, intent: intent, update: { _, intent in
            received = intent
            return updated
        })
        XCTAssertTrue(result === updated)
        XCTAssertTrue(received === intent)
    }

    // The real system update, where the test process allows it: the banner keeps what tapping
    // and the app's ringing teardown read (title, sound, category, thread, userInfo).
    @available(iOS 15.0, *)
    func testSystemUpdateKeepsWhatTheBannerHad() throws {
        let content = self.ringingContent()
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(accountId: 42, peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
        let intent = IncomingCallCommunication.intent(caller: IncomingCallCommunication.person(caller, name: "Alice", image: nil), callId: 1, isVideo: false, date: Date())
        let updated: UNNotificationContent
        do {
            updated = try content.updating(from: intent)
        } catch let error {
            throw XCTSkip("the test process cannot update content from an intent: \(error)")
        }
        XCTAssertEqual(updated.body, "is calling you")
        XCTAssertEqual(updated.threadIdentifier, "1234")
        XCTAssertEqual(updated.categoryIdentifier, "c")
        XCTAssertEqual(updated.sound, content.sound)
        XCTAssertTrue(IncomingCallPushPresentation.isIncomingCall(userInfo: updated.userInfo))
        XCTAssertEqual(updated.userInfo["accountId"] as? String, "42")
        XCTAssertEqual(updated.userInfo["peerId"] as? String, "1234")
    }

    // MARK: - A caller that is not drawn

    // The ringtone needs content updated from a call intent, so a call that is not drawn gets an
    // anonymous one: no photo, no device contact, and a handle nothing can call back.
    @available(iOS 15.0, *)
    func testAnonymousPersonCarriesNothingToCallBack() {
        let person = IncomingCallCommunication.anonymousPerson(name: "Incoming Call")
        XCTAssertEqual(person.displayName, "Incoming Call")
        XCTAssertNil(person.image)
        XCTAssertNil(person.contactIdentifier)
        XCTAssertNil(person.customIdentifier)
        XCTAssertFalse(person.isMe)
        XCTAssertNil(person.personHandle?.value.flatMap(IncomingCallNotifications.callBack(identifier:)))
        XCTAssertEqual(person.personHandle?.value, IncomingCallCommunication.anonymousHandle)
    }

    @available(iOS 15.0, *)
    func testAnonymousIntentStillRingsAsANormalCall() {
        let person = IncomingCallCommunication.anonymousPerson(name: "Incoming Call")
        let intent = IncomingCallCommunication.intent(caller: person, callId: 9, isVideo: false, date: Date())
        XCTAssertEqual(intent.destinationType, .normal)
        XCTAssertEqual(intent.callCapability, .audioCall)
        XCTAssertNotNil(intent.callRecordToCallBack)
    }

    // A group call invite is no call to the inviter: nothing to call back.
    @available(iOS 15.0, *)
    func testGroupInviteIntentHasNoCallRecordToCallBack() {
        let person = IncomingCallCommunication.anonymousPerson(name: "Group")
        let intent = IncomingCallCommunication.intent(caller: person, callId: 9, isVideo: true, date: Date(), callsBack: false)
        XCTAssertNil(intent.callRecordToCallBack)
        XCTAssertEqual(intent.destinationType, .normal)
        XCTAssertEqual(intent.callCapability, .videoCall)
    }

    // The system refusing the intent leaves the banner, which then rings with a bundled sound.
    @available(iOS 15.0, *)
    func testRefusedUpdateFallsBackToABundledSound() {
        let content = self.ringingContent()
        let person = IncomingCallCommunication.anonymousPerson(name: "Alice")
        let intent = IncomingCallCommunication.intent(caller: person, callId: 1, isVideo: false, date: Date())
        let updated = IncomingCallCommunication.updatedContent(content, intent: intent, update: { _, _ in
            throw UpdateFailure.refused
        })
        let result = IncomingCallCommunication.withFallbackSound(original: content, updated: updated)
        XCTAssertEqual(result.sound, IncomingCallPushPresentation.fallbackSound)
        XCTAssertEqual(result.title, "Alice")
        XCTAssertEqual(result.body, "is calling you")
        XCTAssertTrue(IncomingCallPushPresentation.isIncomingCall(userInfo: result.userInfo))
    }

    @available(iOS 15.0, *)
    func testAcceptedUpdateKeepsItsSound() {
        let content = self.ringingContent()
        let updated = UNMutableNotificationContent()
        updated.sound = .default
        let result = IncomingCallCommunication.withFallbackSound(original: content, updated: updated)
        XCTAssertTrue(result === updated)
        XCTAssertEqual(result.sound, UNNotificationSound.default)
    }
}
