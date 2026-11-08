import XCTest
@testable import Postbox

/// The Intents extension crashed (SIGSEGV in `TempBox.__deallocating_deinit`) when several handlers initialized the shared
/// TempBox at once: the unguarded global released its previous value twice. Concurrent initializations must be safe and
/// leave a usable shared instance.
final class TempBoxConcurrentInitTests: XCTestCase {
    func testConcurrentInitializationsDoNotCrash() {
        let basePath = NSTemporaryDirectory() + "TempBoxConcurrentInitTests"
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            TempBox.initializeShared(basePath: basePath, processType: "tests", launchSpecificId: Int64(index))
            _ = TempBox.shared
        }
        XCTAssertNotNil(TempBox.shared.tempFile(fileName: "check.bin"))
    }
}
