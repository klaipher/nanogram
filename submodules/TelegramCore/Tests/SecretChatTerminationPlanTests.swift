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

    func testSequenceBasedChatFlushesInItsActiveLayer() {
        let negotiation = SecretChatLayerNegotiationState(activeLayer: .layer101, locallyRequestedLayer: nil, remotelyRequestedLayer: nil)
        let state = SecretChatSequenceBasedLayerState(layerNegotiationState: negotiation, rekeyState: nil, baseIncomingOperationIndex: 0, baseOutgoingOperationIndex: 0, topProcessedCanonicalIncomingOperationIndex: nil)
        XCTAssertEqual(secretChatTerminationPlan(embeddedState: .sequenceBasedLayer(state), requestRemoteHistoryRemoval: true), .flushHistoryThenTerminate(layer: .layer101))
    }

    func testAHandshakeChatTerminatesAtOnce() {
        XCTAssertEqual(secretChatTerminationPlan(embeddedState: .handshake(.accepting), requestRemoteHistoryRemoval: true), .terminateNow)
    }

    func testASecondRequestFoldsIntoTheQueuedTerminate() {
        XCTAssertEqual(secretChatTerminationPlan(embeddedState: .basicLayer, requestRemoteHistoryRemoval: false, terminationQueued: true), .foldIntoQueuedTermination)
        XCTAssertEqual(secretChatTerminationPlan(embeddedState: .basicLayer, requestRemoteHistoryRemoval: true, terminationQueued: true), .foldIntoQueuedTermination)
    }
}

final class TranslationFallbackTests: XCTestCase {
    func testTheUserSwitchNeverFallsBackToTheServer() {
        XCTAssertFalse(translationFallsBackToServer(localOnly: true))
        XCTAssertTrue(translationFallsBackToServer(localOnly: false))
    }
}
