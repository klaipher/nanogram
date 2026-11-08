import XCTest
@testable import ChatEntityKeyboardInputNode

final class OffMainReleaseTests: XCTestCase {
    private final class Probe {
        let onDeinit: (Bool) -> Void
        init(onDeinit: @escaping (Bool) -> Void) {
            self.onDeinit = onDeinit
        }
        deinit {
            self.onDeinit(Thread.isMainThread)
        }
    }

    func testLastReferenceIsFreedOffTheMainThread() {
        let freed = expectation(description: "freed")
        var freedOnMain: Bool?
        var probe: Probe? = Probe(onDeinit: { isMain in
            freedOnMain = isMain
            freed.fulfill()
        })
        OffMainRelease.release([[probe as Any]], after: 0.05)
        probe = nil
        XCTAssertNil(freedOnMain, "dropping the caller's reference must not free the data")
        wait(for: [freed], timeout: 5.0)
        XCTAssertEqual(freedOnMain, false)
    }

    func testEmptyInputSchedulesNothing() {
        OffMainRelease.release([], after: 0.0)
    }
}
