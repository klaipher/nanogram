import XCTest
@testable import tgwatch_Watch_App

/// The QR login screen names this app; the phone it is scanned from may run Nanogram or Telegram.
final class QrLoginBrandingTests: XCTestCase {
    func testTitleNamesNanogram() {
        XCTAssertEqual(QrLoginContent.title, "Log in to Nanogram by QR Code")
    }

    func testFirstStepOffersNanogramOrTelegram() {
        XCTAssertEqual(QrLoginContent.steps.first, "Open Nanogram or Telegram on your phone")
        XCTAssertEqual(Array(QrLoginContent.steps.dropFirst()), ["Settings", "Devices", "Scan QR"])
    }
}
