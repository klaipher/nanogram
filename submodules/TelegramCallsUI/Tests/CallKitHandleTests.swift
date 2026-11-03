import XCTest
import TelegramCore
@testable import TelegramCallsUI

// Phone ▸ Recents and Siri call suggestions hand the app back the handle it wrote (CXHandle,
// the donated INPerson). Handles name the account and the packed peer id; the older forms (a raw
// user id, "tg<raw user id>", "tg<packed peer id>") still sit in Recents and must keep working.
final class CallKitHandleTests: XCTestCase {
    private func user(_ id: Int64) -> EnginePeer.Id {
        return EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(id))
    }

    func testHandleRoundTripsA64BitUserId() {
        let peerId = self.user(6_000_000_000)
        let handle = CallKitHandle.value(accountId: AccountRecordId(rawValue: -42), peerId: peerId)
        XCTAssertEqual(CallKitHandle.parse(handle), CallKitHandle.Parsed(accountId: AccountRecordId(rawValue: -42), peerId: peerId))
    }

    func testLegacyRawUserIdsDecodeAsUsers() {
        for raw: Int64 in [1234, 4_294_967_295, 4_294_967_296, 6_000_000_000, 8_000_000_000, 34_359_738_367] {
            XCTAssertEqual(CallKitHandle.parse("\(raw)"), CallKitHandle.Parsed(accountId: nil, peerId: self.user(raw)), "\(raw)")
            XCTAssertEqual(CallKitHandle.parse("tg\(raw)"), CallKitHandle.Parsed(accountId: nil, peerId: self.user(raw)), "tg\(raw)")
        }
    }

    func testLegacyPackedUserIdsDecodeAsUsers() {
        let peerId = self.user(6_000_000_000)
        XCTAssertEqual(CallKitHandle.parse("tg\(peerId.toInt64())"), CallKitHandle.Parsed(accountId: nil, peerId: peerId))
    }

    func testOtherHandlesAreNotCalls() {
        for value in ["", "tg", "Unknown", "+15551234567", "@user", "tg-5", "-5", "0", "nanogram-call:1:x"] {
            XCTAssertNil(CallKitHandle.parse(value), value)
        }
    }
}
