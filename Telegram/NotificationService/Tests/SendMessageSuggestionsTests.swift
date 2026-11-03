import XCTest
import NotificationsPresentationData

final class SendMessageSuggestionsTests: XCTestCase {
    private typealias Target = SendMessageSuggestions.Target

    // The app's donations and the notification extension's must name a chat the same way, and
    // per-chat removal must match what was donated.
    func testDonatedIdentityIsTheTgForm() {
        XCTAssertEqual(SendMessageSuggestions.conversationIdentifier(peerId: 123), "tg123")
        XCTAssertEqual(SendMessageSuggestions.groupIdentifier(peerId: 123), "sendMessage_123")
        XCTAssertEqual(SendMessageSuggestions.target(identifier: SendMessageSuggestions.conversationIdentifier(peerId: 8_589_934_593)), Target(accountPeerId: nil, peerId: 8_589_934_593))
    }

    // Older notification donations (and Siri replies) carry a bare id; an account-qualified form
    // is accepted for the future.
    func testReadersAcceptEveryForm() {
        XCTAssertEqual(SendMessageSuggestions.target(identifier: "tg42"), Target(accountPeerId: nil, peerId: 42))
        XCTAssertEqual(SendMessageSuggestions.target(identifier: "42"), Target(accountPeerId: nil, peerId: 42))
        XCTAssertEqual(SendMessageSuggestions.target(identifier: "tg7:42"), Target(accountPeerId: 7, peerId: 42))
        XCTAssertEqual(SendMessageSuggestions.target(identifier: "tg-5"), Target(accountPeerId: nil, peerId: -5))
    }

    func testUnparsableIdentifiersNameNothing() {
        for identifier in ["", "tg", "tg:", "7:42", "tg7:", "tg:42", "tg1:2:3", "nanogram-call:1:2", "device-contact-42", "tgabc"] {
            XCTAssertNil(SendMessageSuggestions.target(identifier: identifier), identifier)
        }
    }

    // The conversation wins; recipients are a fallback, and an incoming donation's only
    // recipient (the account itself) has no identifier.
    func testConversationFirstThenRecipients() {
        XCTAssertEqual(SendMessageSuggestions.target(conversationIdentifier: "tg1", recipientCustomIdentifiers: ["tg2"]), Target(accountPeerId: nil, peerId: 1))
        XCTAssertEqual(SendMessageSuggestions.target(conversationIdentifier: nil, recipientCustomIdentifiers: [nil, "tg2"]), Target(accountPeerId: nil, peerId: 2))
        XCTAssertEqual(SendMessageSuggestions.target(conversationIdentifier: "garbage", recipientCustomIdentifiers: ["tg2"]), Target(accountPeerId: nil, peerId: 2))
        XCTAssertNil(SendMessageSuggestions.target(conversationIdentifier: nil, recipientCustomIdentifiers: [nil]))
    }

    // I-6: a suggestion opens in the suggestions account, not whichever account is current.
    func testSuggestionOpensInTheSuggestionsAccount() {
        let target = Target(accountPeerId: nil, peerId: 42)
        XCTAssertEqual(SendMessageSuggestions.accountPeerId(for: target, suggestionsAccountPeerId: 100, signedInAccountPeerIds: [200, 100]), 100)
        // Named in the identifier: that account wins.
        XCTAssertEqual(SendMessageSuggestions.accountPeerId(for: Target(accountPeerId: 200, peerId: 42), suggestionsAccountPeerId: 100, signedInAccountPeerIds: [200, 100]), 200)
        // An account that signed out is never chosen: the caller falls back to its current one.
        XCTAssertNil(SendMessageSuggestions.accountPeerId(for: target, suggestionsAccountPeerId: 300, signedInAccountPeerIds: [200, 100]))
        XCTAssertEqual(SendMessageSuggestions.accountPeerId(for: Target(accountPeerId: 300, peerId: 42), suggestionsAccountPeerId: 100, signedInAccountPeerIds: [100]), 100)
        XCTAssertNil(SendMessageSuggestions.accountPeerId(for: target, suggestionsAccountPeerId: nil, signedInAccountPeerIds: [100]))
    }

    // I-12: the notification extension applies the user's Siri & Search choices like the app.
    func testDonationRules() {
        let rules = SendMessageSuggestions.Rules(accountPeerId: 100, contacts: true, privateChats: false, groups: false, savedMessages: true, onlyShared: false)
        XCTAssertTrue(rules.allowsDonation(subject: .contact, donorAccountPeerId: 100, isArchived: false, hasPasscode: false))
        XCTAssertTrue(rules.allowsDonation(subject: .savedMessages, donorAccountPeerId: 100, isArchived: false, hasPasscode: false))
        XCTAssertFalse(rules.allowsDonation(subject: .privateChat, donorAccountPeerId: 100, isArchived: false, hasPasscode: false))
        XCTAssertFalse(rules.allowsDonation(subject: .group, donorAccountPeerId: 100, isArchived: false, hasPasscode: false))
        XCTAssertFalse(rules.allowsDonation(subject: .never, donorAccountPeerId: 100, isArchived: false, hasPasscode: false))
        // Another account's messages, archived chats and anything while a passcode is set are not donated.
        XCTAssertFalse(rules.allowsDonation(subject: .contact, donorAccountPeerId: 200, isArchived: false, hasPasscode: false))
        XCTAssertFalse(rules.allowsDonation(subject: .contact, donorAccountPeerId: 100, isArchived: true, hasPasscode: false))
        XCTAssertFalse(rules.allowsDonation(subject: .contact, donorAccountPeerId: 100, isArchived: false, hasPasscode: true))
        // No suggestions account chosen yet: every account donates.
        let anyAccount = SendMessageSuggestions.Rules(accountPeerId: nil, contacts: true, privateChats: true, groups: true, savedMessages: true, onlyShared: false)
        XCTAssertTrue(anyAccount.allowsDonation(subject: .group, donorAccountPeerId: 200, isArchived: false, hasPasscode: false))
        // "Only shared chats": a received message is not a share.
        let onlyShared = SendMessageSuggestions.Rules(accountPeerId: nil, contacts: true, privateChats: true, groups: true, savedMessages: true, onlyShared: true)
        XCTAssertFalse(onlyShared.allowsDonation(subject: .contact, donorAccountPeerId: 100, isArchived: false, hasPasscode: false))
        XCTAssertTrue(onlyShared.allowsDonation(subject: .contact, donorAccountPeerId: 100, isArchived: false, hasPasscode: false, isShare: true))
    }
}

final class ForegroundNotificationPresentationTests: XCTestCase {
    // I-22: the decision behind `willPresent`, which now always answers.
    func testBannerOnlyForAnotherAccountOrALink() {
        XCTAssertTrue(ForegroundNotificationPresentation.showsBanner(notificationAccountId: 2, currentAccountId: 1, hasUrl: false))
        XCTAssertTrue(ForegroundNotificationPresentation.showsBanner(notificationAccountId: 1, currentAccountId: 1, hasUrl: true))
        XCTAssertFalse(ForegroundNotificationPresentation.showsBanner(notificationAccountId: 1, currentAccountId: 1, hasUrl: false))
        XCTAssertFalse(ForegroundNotificationPresentation.showsBanner(notificationAccountId: nil, currentAccountId: 1, hasUrl: true))
        XCTAssertFalse(ForegroundNotificationPresentation.showsBanner(notificationAccountId: 2, currentAccountId: nil, hasUrl: false))
    }
}
