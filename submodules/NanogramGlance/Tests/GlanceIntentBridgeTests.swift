import XCTest
@testable import NanogramGlance

final class GlanceIntentBridgeTests: XCTestCase {
    func testWaitReturnsNilWithoutHandlerAndTheHandlerOnceRegistered() async {
        let bridge = GlanceIntentBridge()
        let none = await bridge.waitForHandler(timeout: 0.2)
        XCTAssertNil(none)
        await bridge.register(GlanceIntentHandler(openChat: { _, _ in true }, sendToSavedMessages: { _, _ in .queued }, stopLiveLocation: { _, _ in }, endCall: {}))
        let handler = await bridge.waitForHandler(timeout: 0.2)
        let sent = await handler?.sendToSavedMessages(nil, "hi")
        XCTAssertEqual(sent, .queued)
    }
}
