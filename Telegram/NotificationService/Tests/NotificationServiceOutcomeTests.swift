import XCTest
import UserNotifications
@testable import NotificationServiceExtensionLib

/// The extension's short log (`critlog-*.txt`) held ~50 lines of database setup per push and never said how the push
/// ended. Each request now ends with one short-log line: what was handed back, whether it was a call, how long it
/// took and whether the system's time ran out. It carries no content and no ids beyond the random episode.
final class NotificationServiceOutcomeTests: XCTestCase {
    private func content(body: String, userInfo: [AnyHashable: Any] = [:]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.body = body
        content.userInfo = userInfo
        return content
    }

    func testWhatWasHandedBack() {
        XCTAssertEqual(NotificationServiceOutcome.delivered(generated: false, result: nil), .nothing)
        XCTAssertEqual(NotificationServiceOutcome.delivered(generated: true, result: nil), .nothing)
        // The extension produced nothing: the server's own alert goes out.
        XCTAssertEqual(NotificationServiceOutcome.delivered(generated: false, result: (self.content(body: "You have a new message"), false)), .serverAlert)
        XCTAssertEqual(NotificationServiceOutcome.delivered(generated: true, result: (self.content(body: "You have a new message"), true)), .quietPlaceholder)
        XCTAssertEqual(NotificationServiceOutcome.delivered(generated: true, result: (self.content(body: ""), false)), .silent)
        XCTAssertEqual(NotificationServiceOutcome.delivered(generated: true, result: (self.content(body: "Hello"), false)), .alert)
    }

    func testACallIsSeenInTheGeneratedOrTheHandedBackContent() {
        let ring = IncomingCallPushPresentation.markerUserInfo
        let quiet = IncomingCallPushPresentation.quietUserInfo
        XCTAssertTrue(NotificationServiceOutcome.isCall(generatedUserInfo: ring, deliveredUserInfo: ring))
        // A quieted call: the extension made a ring, the content handed back has only the quiet marker.
        XCTAssertTrue(NotificationServiceOutcome.isCall(generatedUserInfo: ring, deliveredUserInfo: quiet))
        XCTAssertTrue(NotificationServiceOutcome.isCall(generatedUserInfo: nil, deliveredUserInfo: quiet))
        // An empty call alert: the server's own payload goes back, without any marker.
        XCTAssertTrue(NotificationServiceOutcome.isCall(generatedUserInfo: ring, deliveredUserInfo: ["aps": ["alert": "Call"]]))
        XCTAssertFalse(NotificationServiceOutcome.isCall(generatedUserInfo: ["peerId": "1"], deliveredUserInfo: ["aps": ["alert": "Hi"]]))
        XCTAssertFalse(NotificationServiceOutcome.isCall(generatedUserInfo: nil, deliveredUserInfo: nil))
    }

    func testTheLineSaysHowTheRequestEnded() {
        XCTAssertEqual(
            NotificationServiceOutcome.line(episode: "a1b2c3", ending: .completed, delivered: .alert, isCall: false, duration: 1.234),
            "NotificationService a1b2c3 outcome: alert after 1.23 s"
        )
        XCTAssertEqual(
            NotificationServiceOutcome.line(episode: "a1b2c3", ending: .timeExpired, delivered: .serverAlert, isCall: true, duration: 29.9),
            "NotificationService a1b2c3 outcome: server alert, call after 29.90 s, time expired"
        )
        XCTAssertEqual(
            NotificationServiceOutcome.line(episode: "ff", ending: .completed, delivered: .quietPlaceholder, isCall: false, duration: 0.0),
            "NotificationService ff outcome: quiet placeholder after 0.00 s"
        )
        XCTAssertEqual(
            NotificationServiceOutcome.line(episode: "ff", ending: .completed, delivered: .nothing, isCall: false, duration: 0.5),
            "NotificationService ff outcome: nothing after 0.50 s"
        )
        XCTAssertEqual(
            NotificationServiceOutcome.line(episode: "ff", ending: .completed, delivered: .silent, isCall: false, duration: 0.5),
            "NotificationService ff outcome: silent after 0.50 s"
        )
    }

    func testABadClockDoesNotTrap() {
        let line = NotificationServiceOutcome.line(episode: "ff", ending: .completed, delivered: .alert, isCall: false, duration: -Double.infinity)
        XCTAssertTrue(line.hasPrefix("NotificationService ff outcome: alert after "))
        let nanLine = NotificationServiceOutcome.line(episode: "ff", ending: .completed, delivered: .alert, isCall: false, duration: Double.nan)
        XCTAssertTrue(nanLine.hasPrefix("NotificationService ff outcome: alert after "))
    }
}
