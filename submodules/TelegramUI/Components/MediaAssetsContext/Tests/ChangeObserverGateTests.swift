import Foundation
import Photos
import XCTest
@testable import MediaAssetsContext

final class ChangeObserverGateTests: XCTestCase {
    func testNothingRegistersWithoutAccess() {
        let gate = ChangeObserverGate()
        XCTAssertFalse(gate.shouldRegister(for: .notDetermined))
        XCTAssertFalse(gate.shouldRegister(for: .denied))
        XCTAssertFalse(gate.shouldRegister(for: .restricted))
        XCTAssertFalse(gate.isRegistered)
    }

    func testAuthorizedAndLimitedRegisterOnce() {
        let authorized = ChangeObserverGate()
        XCTAssertTrue(authorized.shouldRegister(for: .authorized))
        XCTAssertFalse(authorized.shouldRegister(for: .authorized))
        XCTAssertTrue(authorized.isRegistered)

        let limited = ChangeObserverGate()
        XCTAssertTrue(limited.shouldRegister(for: .limited))
        XCTAssertFalse(limited.shouldRegister(for: .authorized), "a Limited to Full change keeps the registration")
    }

    func testAccessGrantedLaterRegistersThen() {
        let gate = ChangeObserverGate()
        XCTAssertFalse(gate.shouldRegister(for: .notDetermined))
        XCTAssertTrue(gate.shouldRegister(for: .limited))
    }

    func testConcurrentCallersRegisterExactlyOnce() {
        let gate = ChangeObserverGate()
        let count = NSLock()
        var wins = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if gate.shouldRegister(for: .authorized) {
                count.lock()
                wins += 1
                count.unlock()
            }
        }
        XCTAssertEqual(wins, 1)
    }
}
