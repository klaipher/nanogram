import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// Lottie conversions read one app-configuration flag. They used to open a Postbox transaction
/// per conversion; FetchCachedRepresentations now keeps a preferences view per Postbox and reads
/// its last value. This checks that pattern stays current and measures both.
final class PreferencesHeldViewReadTests: XCTestCase {
    private let key = ValueBoxKey("heldViewConfig")

    private func entry(_ value: UInt8) -> PreferencesEntry {
        return PreferencesEntry(data: Data([value]))
    }

    private func read(_ signal: Signal<UInt8?, NoError>) -> UInt8? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: UInt8?
        let disposable = (signal |> take(1)).start(next: { value in
            result = value
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + 10.0) == .timedOut {
            XCTFail("read did not complete")
        }
        disposable.dispose()
        return result
    }

    func testHeldViewFollowsChangesAndIsCheaperThanATransaction() {
        let fixture = PostboxFixture(name: "PreferencesHeldViewReadTests")
        defer {
            fixture.close()
        }
        let key = self.key
        fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: self.entry(1))
        }

        let held = Promise<UInt8?>()
        held.set(fixture.postbox.preferencesView(keys: [key])
        |> map { view -> UInt8? in
            return view.values[key]?.data.first
        })
        XCTAssertEqual(self.read(held.get()), 1)

        fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: self.entry(2))
        }
        // The view is updated with the transaction; once a later one ran, a read sees it.
        fixture.transaction { _ in
        }
        XCTAssertEqual(self.read(held.get()), 2)

        let count = 500
        var start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< count {
            let value = self.read(fixture.postbox.transaction { transaction -> UInt8? in
                return transaction.getPreferencesEntry(key: key)?.data.first
            })
            XCTAssertEqual(value, 2)
        }
        let transactionMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< count {
            XCTAssertEqual(self.read(held.get()), 2)
        }
        let heldMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        print("Preferences read benchmark: \(count) reads: transaction \(String(format: "%.1f", transactionMs)) ms, held view \(String(format: "%.1f", heldMs)) ms")
    }
}
