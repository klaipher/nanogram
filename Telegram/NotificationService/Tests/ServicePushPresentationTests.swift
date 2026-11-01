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

    func testOnlyTheOfficialBundleCanFilter() {
        XCTAssertTrue(ServicePushPresentation.appCanFilterNotifications(baseAppBundleId: "ph.telegra.Telegraph"))
        XCTAssertFalse(ServicePushPresentation.appCanFilterNotifications(baseAppBundleId: "org.klaipher.Nanogram"))
    }

    func testBaseAppBundleIdDropsTheExtensionSuffix() {
        XCTAssertEqual(ServicePushPresentation.baseAppBundleId(extensionBundleId: "org.klaipher.Nanogram.NotificationService"), "org.klaipher.Nanogram")
        XCTAssertNil(ServicePushPresentation.baseAppBundleId(extensionBundleId: "NoDots"))
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

    // A silent push without an alert shows nothing either way; nothing to make quiet.
    func testEmptyContentForSilentPushIsKept() {
        let generated = UNMutableNotificationContent()
        let result = ServicePushPresentation.presentation(generated: generated, initialContent: UNMutableNotificationContent(), canFilter: false)
        XCTAssertFalse(result.isQuietPlaceholder)
    }
}
