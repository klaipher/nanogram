import Foundation
import XCTest
@testable import TelegramCore

final class SecretChatTerminationPlanTests: XCTestCase {
    func testDeleteForEveryoneFlushesHistoryBeforeTerminating() {
        XCTAssertEqual(secretChatTerminationPlan(embeddedState: .basicLayer, requestRemoteHistoryRemoval: true), .flushHistoryThenTerminate(layer: .layer8))
    }

    func testDeleteOnlyForMeTerminatesAtOnce() {
        XCTAssertEqual(secretChatTerminationPlan(embeddedState: .basicLayer, requestRemoteHistoryRemoval: false), .terminateNow)
    }

    func testAChatThatCannotSendTerminatesAtOnce() {
        XCTAssertEqual(secretChatTerminationPlan(embeddedState: .terminated, requestRemoteHistoryRemoval: true), .terminateNow)
    }
}
