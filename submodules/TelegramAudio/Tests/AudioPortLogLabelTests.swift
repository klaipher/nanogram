import XCTest
import AVFoundation
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

    // MARK: - Output modes in log lines

    /// The call's audio menu offers AirPods as `.port`, and picking them sends `.custom(.port(...))`, which
    /// `ManagedAudioSession` writes into its setup, output request and voice chat lines as it is.
    private func pickedAirPods() -> AudioSessionOutput? {
        let iPhoneMic = AudioSessionRoutePort(portType: .builtInMic, uid: "Built-In Microphone", name: "iPhone Microphone")
        let airPods = AudioSessionRoutePort(portType: .bluetoothHFP, uid: "AA:BB:CC:DD:EE:FF-tsco", name: "Alice's AirPods Pro")
        let route = AudioSessionRoute(outputs: [airPods], inputs: [airPods], availableInputs: [iPhoneMic, airPods])
        let current = audioSessionOutputs(route: route, hasLoudspeaker: true).current
        guard case .port = current else {
            XCTFail("AirPods are not offered as a port: \(current)")
            return nil
        }
        return current
    }

    func testAPickedPortIsDescribedByKindAndTagOnly() {
        guard let airPods = self.pickedAirPods() else {
            return
        }
        let texts = [
            String(describing: AudioSessionOutputMode.custom(airPods)),
            String(reflecting: AudioSessionOutputMode.custom(airPods)),
            "\(AudioSessionOutputMode.custom(airPods))",
            String(describing: airPods),
            String(reflecting: airPods),
            String(describing: [airPods]),
        ]
        for text in texts {
            XCTAssertFalse(text.contains("Alice"), text)
            XCTAssertFalse(text.contains("AirPods"), text)
            XCTAssertFalse(text.contains("AA:BB"), "the uid of a Bluetooth port holds its address: \(text)")
            XCTAssertFalse(text.contains("tsco"), text)
        }
        XCTAssertEqual("\(AudioSessionOutputMode.custom(airPods))", "custom(port(bluetooth#539f39))")
    }

    func testDumpShowsNeitherTheNameNorTheUid() {
        guard let airPods = self.pickedAirPods() else {
            return
        }
        var text = ""
        dump(AudioSessionOutputMode.custom(airPods), to: &text)
        XCTAssertFalse(text.contains("Alice"), text)
        XCTAssertFalse(text.contains("AA:BB"), text)
    }

    func testTheOtherModesKeepTheirNames() {
        XCTAssertEqual("\(AudioSessionOutputMode.system)", "system")
        XCTAssertEqual("\(AudioSessionOutputMode.speakerIfNoHeadphones)", "speakerIfNoHeadphones")
        XCTAssertEqual("\(AudioSessionOutputMode.custom(.speaker))", "custom(speaker)")
        XCTAssertEqual("\(AudioSessionOutputMode.custom(.builtin))", "custom(builtin)")
        XCTAssertEqual("\(AudioSessionOutputMode.custom(.headphones))", "custom(headphones)")
    }
}
