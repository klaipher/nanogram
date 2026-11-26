import XCTest
import TelegramAudio

/// Audio route lines go to the always-on critical log, which the report does not mask. A port's name is the one the
/// user gave the device ("<first name>'s AirPods Pro"), so the logs carry its type and a stable tag of its uid instead.
final class AudioPortLogLabelTests: XCTestCase {
    /// FNV-1a 32-bit reference values: "" is the offset basis, "a" the published test vector.
    func testTheTagIsTheTopOfTheFnv1aHashOfTheUid() {
        XCTAssertEqual(audioPortLogTag(uid: ""), "811c9d")
        XCTAssertEqual(audioPortLogTag(uid: "a"), "e40c29")
        XCTAssertEqual(audioPortLogTag(uid: "00:11:22:33:44:55-tacl"), "db54b5")
        XCTAssertEqual(audioPortLogTag(uid: "Wired Headphones"), "0f3b5e")
    }

    func testTheTagIsStableAndTellsDevicesApart() {
        XCTAssertEqual(audioPortLogTag(uid: "00:11:22:33:44:55-tacl"), audioPortLogTag(uid: "00:11:22:33:44:55-tacl"))
        XCTAssertNotEqual(audioPortLogTag(uid: "00:11:22:33:44:55-tacl"), audioPortLogTag(uid: "AA:BB:CC:DD:EE:FF-tacl"))
    }

    func testAnExternalPortIsLoggedByTypeAndTagOnly() {
        let label = audioPortLogLabel(portType: "BluetoothA2DPOutput", uid: "00:11:22:33:44:55-tacl")
        XCTAssertEqual(label, "BluetoothA2DPOutput#db54b5")
        XCTAssertFalse(label.contains("00:11:22"), "the uid of a Bluetooth port holds its address")
    }

    func testThePhonesOwnPortsAreLoggedByTypeAlone() {
        XCTAssertEqual(audioPortLogLabel(portType: "MicrophoneBuiltIn", uid: "Built-In Microphone"), "MicrophoneBuiltIn")
        XCTAssertEqual(audioPortLogLabel(portType: "Receiver", uid: "Built-In Receiver"), "Receiver")
        XCTAssertEqual(audioPortLogLabel(portType: "Speaker", uid: "Speaker"), "Speaker")
    }

    func testTheRouteLineIsWrittenOnlyWhenItChanges() {
        var deduplicator = AudioRouteLogDeduplicator()
        XCTAssertTrue(deduplicator.shouldLog("route A"))
        XCTAssertFalse(deduplicator.shouldLog("route A"))
        XCTAssertFalse(deduplicator.shouldLog("route A"))
        XCTAssertTrue(deduplicator.shouldLog("route B"))
        XCTAssertTrue(deduplicator.shouldLog("route A"))
    }
}
