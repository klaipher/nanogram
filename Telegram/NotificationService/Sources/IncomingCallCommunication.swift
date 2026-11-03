import Foundation
import Intents
import UserNotifications
import NotificationsPresentationData

/// The ringing call notification (`IncomingCallPushPresentation`) as a communication notification
/// for a call: the content is updated from an `INStartCallIntent` naming the caller, so iOS draws
/// the caller's photo on it, as it draws the sender's on a message. It is also what makes
/// `UNNotificationSound.defaultRingtone` ring: the SDK plays the ringtone only for content updated
/// from an `INStartCallIntent` with a normal destination.
@available(iOS 15.0, *)
enum IncomingCallCommunication {
    struct Caller: Equatable {
        var accountId: Int64
        var peerId: Int64
        /// The name the notification is drawn with: the system draws the title from it and hides the
        /// subtitle, so it is the banner's title, with the account it was delivered to.
        var displayedName: String
        /// The name handed to the system with the donated interaction (the caller alone).
        var donatedName: String
        var contactIdentifier: String?
    }

    /// Nil without a name: the "Incoming Call" banner then stays as it is.
    static func caller(accountId: Int64, peerId: Int64, callerName: String?, recipientAccountName: String?, contactIdentifier: String?) -> Caller? {
        guard let callerName, !callerName.isEmpty else {
            return nil
        }
        let names = NotificationNames(title: callerName, senderName: callerName, silent: false, recipientAccountName: recipientAccountName)
        guard let displayedName = names.displayedSenderName, let donatedName = names.donatedSenderName else {
            return nil
        }
        return Caller(accountId: accountId, peerId: peerId, displayedName: displayedName, donatedName: donatedName, contactIdentifier: contactIdentifier)
    }

    /// The handle names the account the call came to and the caller
    /// (`IncomingCallNotifications.callBackIdentifier`), with an unknown type: the app's call-back
    /// handler (an `INStartCallIntent` user activity in `AppDelegate`) calls the caller from that
    /// account.
    static func person(_ caller: Caller, name: String, image: INImage?) -> INPerson {
        let identifier = IncomingCallNotifications.callBackIdentifier(accountId: caller.accountId, peerId: caller.peerId)
        var nameComponents = PersonNameComponents()
        nameComponents.nickname = name
        return INPerson(
            personHandle: INPersonHandle(value: identifier, type: .unknown),
            nameComponents: nameComponents,
            displayName: name,
            image: image,
            contactIdentifier: caller.contactIdentifier,
            customIdentifier: identifier,
            isMe: false,
            suggestionType: .none
        )
    }

    /// Whether the ringing notification is drawn as the caller's (their photo, the interaction
    /// donated) rather than kept as the plain banner. Not while the passcode lock is on, nor with
    /// names hidden on the lock screen: a message then names no sender either. Nor for a group call
    /// invite: calling back the donated caller would place a 1:1 call to the inviter.
    static func drawsCaller(isAppLocked: Bool, displayNameOnLockscreen: Bool, isGroupCall: Bool) -> Bool {
        return !isAppLocked && displayNameOnLockscreen && !isGroupCall
    }

    enum AvatarSource: Equatable {
        /// No picture.
        case none
        /// The caller's stored peer: its photo when downloaded, else its letters (`peerAvatar`).
        case peer
        /// Letters of the name the push carries, for a caller with no stored peer.
        case letters([String])
    }

    /// With names hidden on the lock screen a message shows no sender and no avatar; a call shows no
    /// face either.
    static func avatarSource(displayNameOnLockscreen: Bool, hasCallerPeer: Bool, callerName: String?) -> AvatarSource {
        if !displayNameOnLockscreen {
            return .none
        }
        if hasCallerPeer {
            return .peer
        }
        let letters = self.letters(title: callerName ?? "")
        return letters.isEmpty ? .none : .letters(letters)
    }

    /// The first letters of the first and last words, as an avatar draws a name.
    static func letters(title: String) -> [String] {
        let words = title.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first?.first else {
            return []
        }
        var result = [String(first).uppercased()]
        if words.count > 1, let last = words.last?.first {
            result.append(String(last).uppercased())
        }
        return result
    }

    static func intent(caller: INPerson, callId: Int64?, isVideo: Bool, date: Date) -> INStartCallIntent {
        let capability: INCallCapability = isVideo ? .videoCall : .audioCall
        // The Swift overlay has no initializer with participants (`caller` is deprecated), so this
        // is the refined Objective-C one.
        let record = INCallRecord(
            __identifier: callId.flatMap { "\($0)" } ?? UUID().uuidString,
            dateCreated: date,
            callRecordType: .ringing,
            callCapability: capability,
            callDuration: nil,
            unseen: NSNumber(value: true),
            participants: [caller],
            numberOfCalls: NSNumber(value: 1),
            isCallerIdBlocked: NSNumber(value: false)
        )
        return INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: record,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [caller],
            callCapability: capability
        )
    }

    /// The content updated from the call intent, or the content unchanged when the system refuses
    /// it: the call notification is never lost.
    static func updatedContent(
        _ content: UNNotificationContent,
        intent: INStartCallIntent,
        update: (UNNotificationContent, INStartCallIntent) throws -> UNNotificationContent = { content, intent in
            return try content.updating(from: intent)
        }
    ) -> UNNotificationContent {
        do {
            return try update(content, intent)
        } catch {
            return content
        }
    }
}
