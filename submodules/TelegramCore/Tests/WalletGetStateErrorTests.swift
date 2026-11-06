import XCTest
@testable import TelegramCore

final class WalletGetStateErrorTests: XCTestCase {
    func testOnlyWalletUnavailableIsAuthoritative() {
        let unavailable = WalletGetStateError(code: 400, description: "WALLET_UNAVAILABLE")
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertTrue(unavailable.isAuthoritative)

        for (code, description) in [(400, "SOMETHING_ELSE"), (403, "WALLET_FORBIDDEN"), (406, "WALLET_NOT_READY")] as [(Int32, String)] {
            let error = WalletGetStateError(code: code, description: description)
            XCTAssertEqual(error, .rejected(description))
            XCTAssertFalse(error.isAuthoritative, "\(code) \(description)")
        }
    }

    func testTransientCodesAreGeneric() {
        for code in [Int32(401), 420, 500, 503, 0, -1] {
            let error = WalletGetStateError(code: code, description: "ANYTHING")
            XCTAssertEqual(error, .generic, "\(code)")
            XCTAssertFalse(error.isAuthoritative)
        }
    }

    func testFloodWaitIsParsedAndTransient() {
        let error = WalletGetStateError(code: 420, description: "FLOOD_WAIT_42")
        XCTAssertEqual(error, .floodWait(42))
        XCTAssertFalse(error.isAuthoritative)
        XCTAssertEqual(error.floodWaitSeconds, 42)
        XCTAssertNil(WalletGetStateError.generic.floodWaitSeconds)
        XCTAssertEqual(WalletGetStateError(code: 420, description: "FLOOD_WAIT_x"), .generic)
    }
}
