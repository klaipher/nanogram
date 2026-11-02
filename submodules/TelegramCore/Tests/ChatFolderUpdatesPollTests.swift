import XCTest
import SwiftSignalKit
@testable import TelegramCore

final class ChatFolderUpdatesPollTests: XCTestCase {
    func testTheCheckRepeatsAfterEachInterval() {
        let runs = Atomic<Int>(value: 0)
        let once = Signal<Never, NoError> { subscriber in
            let _ = runs.modify { $0 + 1 }
            subscriber.putCompletion()
            return EmptyDisposable
        }
        let disposable = repeatedChatFolderUpdatesCheck(once, interval: 0.05).start()
        Thread.sleep(forTimeInterval: 0.5)
        disposable.dispose()
        XCTAssertGreaterThanOrEqual(runs.with { $0 }, 3)
    }

    func testTheCheckIntervalFollowsTheOneHourServerPeriod() {
        #if DEBUG
        XCTAssertEqual(chatFolderUpdatesCheckInterval, 10.0)
        #else
        XCTAssertEqual(chatFolderUpdatesCheckInterval, 60.0)
        #endif
        XCTAssertEqual(chatFolderUpdatesCheckInterval(isDebug: false), 60.0)
    }
}
