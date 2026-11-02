import XCTest
import NotificationsPresentationData
@testable import NotificationServiceExtensionLib

// The app's sweep of service-push leftovers the extension could not take down itself.
final class ServicePushNotificationsTests: XCTestCase {
    private let aps: [String: Any] = ["alert": "You have a new message", "mutable-content": 1]

    private func delivered() -> [(identifier: String, userInfo: [AnyHashable: Any])] {
        return [
            ("placeholder", ["aps": self.aps, "p": "encrypted", "nanogram.servicePush": true]),
            ("fallback", ["aps": self.aps, "p": "encrypted"]),
            ("user", ["from_id": "1", "msg_id": "10", "peerId": "1", "accountId": "2"]),
            ("group", ["chat_id": "2", "msg_id": "11"]),
            ("channel", ["channel_id": "3", "msg_id": "12"]),
            ("peer", ["peerId": "4", "msg_id": "13"]),
            ("alertOnly", ["aps": self.aps]),
            ("notTagged", ["aps": self.aps, "p": "encrypted", "nanogram.servicePush": false]),
        ]
    }

    func testTaggedPlaceholdersAndServerFallbacksAreRemovedOnceActive() {
        let result = ServicePushNotifications.staleIdentifiers(delivered: self.delivered(), includeServerFallbacks: true)
        XCTAssertEqual(result, ["placeholder", "fallback"])
    }

    // Before the app is active a fallback may stand for an unread message: keep it.
    func testOnlyTaggedPlaceholdersAreRemovedWhileInactive() {
        let result = ServicePushNotifications.staleIdentifiers(delivered: self.delivered(), includeServerFallbacks: false)
        XCTAssertEqual(result, ["placeholder"])
    }

    // The extension and the app agree on the tag.
    func testExtensionTagIsTheSharedKey() {
        XCTAssertEqual(ServicePushPresentation.userInfoKey, ServicePushNotifications.placeholderUserInfoKey)
        XCTAssertTrue(ServicePushNotifications.isQuietPlaceholder(userInfo: [ServicePushPresentation.userInfoKey: true]))
    }
}
