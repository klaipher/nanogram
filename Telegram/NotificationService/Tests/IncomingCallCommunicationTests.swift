import XCTest
import Intents
import UserNotifications
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
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(peerId: 1234, callerName: "Alice", recipientAccountName: "peter", contactIdentifier: "C-1"))
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
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
        XCTAssertEqual(caller.displayedName, "Alice")
        XCTAssertEqual(caller.donatedName, "Alice")
    }

    // A call without a name keeps the "Incoming Call" banner as it is.
    @available(iOS 15.0, *)
    func testNoCallerWithoutAName() {
        XCTAssertNil(IncomingCallCommunication.caller(peerId: 1234, callerName: nil, recipientAccountName: "peter", contactIdentifier: nil))
        XCTAssertNil(IncomingCallCommunication.caller(peerId: 1234, callerName: "", recipientAccountName: "peter", contactIdentifier: nil))
    }

    // The app's "call back" handler (AppDelegate, INStartCallIntent user activity) reads an
    // unknown-type handle as the peer id.
    @available(iOS 15.0, *)
    func testPersonCarriesThePeerIdAndThePhoto() throws {
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(peerId: 1234, callerName: "Alice", recipientAccountName: "peter", contactIdentifier: "C-1"))
        let image = INImage(imageData: Data([0x1]))
        let person = IncomingCallCommunication.person(caller, name: caller.displayedName, image: image)
        XCTAssertEqual(person.displayName, "Alice → peter")
        XCTAssertEqual(person.personHandle?.value, "1234")
        XCTAssertEqual(person.personHandle?.type, .unknown)
        XCTAssertEqual(person.customIdentifier, "1234")
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
        XCTAssertTrue(IncomingCallCommunication.drawsCaller(isAppLocked: false))
        XCTAssertFalse(IncomingCallCommunication.drawsCaller(isAppLocked: true))
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
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
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
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
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
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
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
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
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
        let caller = try XCTUnwrap(IncomingCallCommunication.caller(peerId: 1234, callerName: "Alice", recipientAccountName: nil, contactIdentifier: nil))
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
}
