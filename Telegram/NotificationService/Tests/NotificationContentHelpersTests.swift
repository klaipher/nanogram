import XCTest
import UIKit
@testable import NotificationServiceExtensionLib

final class NotificationEmojiGlyphTests: XCTestCase {
    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0.0, y: 0.0, width: width, height: height))
        }
    }

    // I-16: an emoji image that is not square, or smaller than the 40 px tile, used to trap the
    // extension (`try!`); it now becomes a glyph or leaves the emoji's text.
    func testOddSizedEmojiImagesDoNotTrap() throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("adaptive image glyphs need iOS 18")
        }
        XCTAssertNotNil(notificationEmojiGlyph(image: image(width: 100.0, height: 80.0), description: "🙂"))
        XCTAssertNotNil(notificationEmojiGlyph(image: image(width: 32.0, height: 32.0), description: "🙂"))
        XCTAssertNotNil(notificationEmojiGlyph(image: image(width: 40.0, height: 40.0), description: "🙂"))
        XCTAssertNil(notificationEmojiGlyph(image: UIImage(), description: "🙂"))
    }
}

final class NotificationLogRedactionTests: XCTestCase {
    // I-21: with redaction on (the default), the notification log keeps no message text or names.
    func testPayloadIsRedacted() {
        let payload: [String: Any] = ["loc_key": "MESSAGE_TEXT", "loc_args": ["Alice", "secret text"], "from_id": "42"]
        let redacted = notificationPayloadLogDescription(payload, redact: true)
        XCTAssertFalse(redacted.contains("secret text"))
        XCTAssertFalse(redacted.contains("Alice"))
        XCTAssertTrue(redacted.contains("MESSAGE_TEXT"))
        XCTAssertTrue(redacted.contains("loc_args"))
        XCTAssertTrue(notificationPayloadLogDescription(payload, redact: false).contains("secret text"))
    }

    func testTextIsRedacted() {
        XCTAssertEqual(notificationLogText("secret", redact: true), "<6 characters>")
        XCTAssertEqual(notificationLogText("secret", redact: false), "\"secret\"")
        XCTAssertEqual(notificationLogText(nil, redact: true), "nil")
    }
}
