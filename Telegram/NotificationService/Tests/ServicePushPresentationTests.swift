import XCTest
import UserNotifications
@testable import NotificationServiceExtensionLib

final class ServicePushPresentationTests: XCTestCase {
    private func placeholder() -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.body = "You have a new message"
        content.sound = .default
        content.userInfo = ["p": "encrypted"]
        return content
    }

    // Telegram/BUILD writes the flag into the extension's Info.plist from the same condition that
    // grants the entitlement; a missing or malformed flag means no entitlement.
    func testFilteringFollowsTheInfoPlistFlag() {
        let key = ServicePushPresentation.filteringInfoPlistKey
        XCTAssertTrue(ServicePushPresentation.appCanFilterNotifications(infoDictionary: [key: true]))
        XCTAssertFalse(ServicePushPresentation.appCanFilterNotifications(infoDictionary: [key: false]))
        XCTAssertFalse(ServicePushPresentation.appCanFilterNotifications(infoDictionary: [key: "YES"]))
        XCTAssertFalse(ServicePushPresentation.appCanFilterNotifications(infoDictionary: [:]))
        XCTAssertFalse(ServicePushPresentation.appCanFilterNotifications(infoDictionary: nil))
    }

    // A read receipt's empty answer becomes a quiet, marked copy of the server's alert.
    func testEmptyContentWithoutFilteringBecomesQuietPlaceholder() {
        let generated = UNMutableNotificationContent()
        generated.badge = 3
        let result = ServicePushPresentation.presentation(generated: generated, initialContent: self.placeholder(), canFilter: false)
        XCTAssertTrue(result.isQuietPlaceholder)
        XCTAssertEqual(result.content.body, "You have a new message")
        XCTAssertNil(result.content.sound)
        XCTAssertEqual(result.content.badge, 3)
        XCTAssertEqual(result.content.interruptionLevel, .passive)
        XCTAssertEqual(result.content.relevanceScore, 0.0)
        XCTAssertEqual(result.content.threadIdentifier, ServicePushPresentation.threadIdentifier)
        XCTAssertTrue(ServicePushPresentation.isQuietPlaceholder(userInfo: result.content.userInfo))
        XCTAssertEqual(result.content.userInfo["p"] as? String, "encrypted")
    }

    // With the entitlement, empty content drops the push, as in the official app.
    func testEmptyContentWithFilteringIsKept() {
        let generated = UNMutableNotificationContent()
        let result = ServicePushPresentation.presentation(generated: generated, initialContent: self.placeholder(), canFilter: true)
        XCTAssertFalse(result.isQuietPlaceholder)
        XCTAssertTrue(ServicePushPresentation.isEmpty(result.content))
    }

    // A message notification is never touched.
    func testMessageContentIsKept() {
        let generated = UNMutableNotificationContent()
        generated.title = "Alice"
        generated.body = "Hi"
        let result = ServicePushPresentation.presentation(generated: generated, initialContent: self.placeholder(), canFilter: false)
        XCTAssertFalse(result.isQuietPlaceholder)
        XCTAssertEqual(result.content.body, "Hi")
        XCTAssertFalse(ServicePushPresentation.isQuietPlaceholder(userInfo: result.content.userInfo))
    }

    // A call push the extension could not turn into an alert keeps the server's alert, sound
    // included: it is never quieted and never removed.
    func testCallPushIsNeverAQuietPlaceholder() {
        let generated = UNMutableNotificationContent()
        generated.userInfo = IncomingCallPushPresentation.markerUserInfo
        let result = ServicePushPresentation.presentation(generated: generated, initialContent: self.placeholder(), canFilter: false)
        XCTAssertFalse(result.isQuietPlaceholder)
        XCTAssertEqual(result.content.body, "You have a new message")
        XCTAssertNotNil(result.content.sound)
        XCTAssertFalse(ServicePushPresentation.isQuietPlaceholder(userInfo: result.content.userInfo))
    }

    // With the entitlement, the call went to CallKit and the empty answer drops the push.
    func testCallPushWithFilteringIsDropped() {
        let generated = UNMutableNotificationContent()
        generated.userInfo = IncomingCallPushPresentation.markerUserInfo
        let result = ServicePushPresentation.presentation(generated: generated, initialContent: self.placeholder(), canFilter: true)
        XCTAssertFalse(result.isQuietPlaceholder)
        XCTAssertTrue(ServicePushPresentation.isEmpty(result.content))
    }

    // A silent push without an alert shows nothing either way; nothing to make quiet.
    func testEmptyContentForSilentPushIsKept() {
        let generated = UNMutableNotificationContent()
        let result = ServicePushPresentation.presentation(generated: generated, initialContent: UNMutableNotificationContent(), canFilter: false)
        XCTAssertFalse(result.isQuietPlaceholder)
    }
}
