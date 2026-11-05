import XCTest
import TelegramAudio

final class AudioRouteClassificationTests: XCTestCase {
    func testSpeakerOnlyRouteIsTheLoudspeaker() {
        XCTAssertEqual(audioRouteDestination(outputPortTypes: ["Speaker"]), .loudspeaker)
    }

    func testReceiverRouteIsTheReceiver() {
        XCTAssertEqual(audioRouteDestination(outputPortTypes: ["Receiver"]), .receiver)
    }

    func testAnyHeadsetWinsOverTheBuiltInPorts() {
        XCTAssertEqual(audioRouteDestination(outputPortTypes: ["BluetoothHFP"]), .headset)
        XCTAssertEqual(audioRouteDestination(outputPortTypes: ["Headphones", "Speaker"]), .headset)
        XCTAssertEqual(audioRouteDestination(outputPortTypes: ["BluetoothA2DPOutput"]), .headset)
        XCTAssertEqual(audioRouteDestination(outputPortTypes: ["BluetoothLE"]), .headset)
    }

    func testUnknownPortsAreOther() {
        XCTAssertEqual(audioRouteDestination(outputPortTypes: ["AirPlay"]), .other)
        XCTAssertEqual(audioRouteDestination(outputPortTypes: ["CarAudio"]), .other)
        XCTAssertEqual(audioRouteDestination(outputPortTypes: []), .other)
    }

    func testLoudspeakerRequestMissedWhenTheRouteStaysOnTheReceiver() {
        XCTAssertTrue(loudspeakerRequestMissedRoute(outputPortTypes: ["Receiver"]))
    }

    func testLoudspeakerRequestNotMissedOnTheSpeakerOrAHeadset() {
        XCTAssertFalse(loudspeakerRequestMissedRoute(outputPortTypes: ["Speaker"]))
        XCTAssertFalse(loudspeakerRequestMissedRoute(outputPortTypes: ["BluetoothA2DPOutput"]))
    }

    func testEmptyRouteIsNotAMiss() {
        XCTAssertFalse(loudspeakerRequestMissedRoute(outputPortTypes: []))
    }
}
