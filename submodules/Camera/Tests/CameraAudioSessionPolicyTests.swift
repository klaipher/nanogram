import XCTest
import AVFoundation
import Camera

/// Pins the capture side of high-quality AirPods recording for round videos.
///
/// The round-video screen pushes `.record(video: false)`, whose audio session asks for
/// `.bluetoothHighQualityRecording` (see `TelegramAudioTests`). That alone does not make the capture
/// session record from a high-quality Bluetooth route: `AVCaptureSession` sends its own opt-in to the
/// capture server and keeps an auxiliary session in its audio device that excludes such routes
/// unless `configuresApplicationAudioSessionForBluetoothHighQualityRecording` is set (iOS 26 SDK,
/// read from AVFCapture). The tests run the policy against a real `AVCaptureSession`.
final class CameraAudioSessionPolicyTests: XCTestCase {
    private func configuration(audio: Bool, isRoundVideo: Bool) -> Camera.Configuration {
        return Camera.Configuration(preset: .hd1920x1080, position: .front, audio: audio, photo: false, metadata: false, isRoundVideo: isRoundVideo)
    }

    private func makeSession() -> AVCaptureSession {
        // The same setup both camera implementations apply before the policy.
        let session = AVCaptureSession()
        session.usesApplicationAudioSession = true
        session.automaticallyConfiguresApplicationAudioSession = false
        return session
    }

    func testOnlyRoundVideoWithAudioCapturesBluetoothHighQualityAudio() {
        XCTAssertTrue(self.configuration(audio: true, isRoundVideo: true).capturesBluetoothHighQualityAudio)
        XCTAssertFalse(self.configuration(audio: false, isRoundVideo: true).capturesBluetoothHighQualityAudio)
        // Story and attachment cameras record under `.videoRecording`, which the option does not support.
        XCTAssertFalse(self.configuration(audio: true, isRoundVideo: false).capturesBluetoothHighQualityAudio)
        XCTAssertFalse(self.configuration(audio: false, isRoundVideo: false).capturesBluetoothHighQualityAudio)
    }

    func testRoundVideoSessionOptsIntoBluetoothHighQualityRecording() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("configuresApplicationAudioSessionForBluetoothHighQualityRecording needs iOS 26")
        }
        let session = self.makeSession()
        XCTAssertFalse(session.configuresApplicationAudioSessionForBluetoothHighQualityRecording, "the system default is off")

        Camera.applyBluetoothHighQualityRecordingPolicy(to: session, configuration: self.configuration(audio: true, isRoundVideo: true))

        XCTAssertTrue(session.configuresApplicationAudioSessionForBluetoothHighQualityRecording)
        // The app keeps owning its audio session: the opt-in must not turn automatic configuration on.
        XCTAssertFalse(session.automaticallyConfiguresApplicationAudioSession)
        XCTAssertTrue(session.usesApplicationAudioSession)
    }

    func testOtherCaptureSessionsKeepTheSystemDefault() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("configuresApplicationAudioSessionForBluetoothHighQualityRecording needs iOS 26")
        }
        for configuration in [self.configuration(audio: true, isRoundVideo: false), self.configuration(audio: false, isRoundVideo: true)] {
            let session = self.makeSession()
            Camera.applyBluetoothHighQualityRecordingPolicy(to: session, configuration: configuration)
            XCTAssertFalse(session.configuresApplicationAudioSessionForBluetoothHighQualityRecording, "audio=\(configuration.audio) isRoundVideo=\(configuration.isRoundVideo)")
        }
    }

    func testMultiCamRoundVideoSessionOptsIn() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("configuresApplicationAudioSessionForBluetoothHighQualityRecording needs iOS 26")
        }
        // Dual-camera round videos use AVCaptureMultiCamSession.
        let session = AVCaptureMultiCamSession()
        session.usesApplicationAudioSession = true
        session.automaticallyConfiguresApplicationAudioSession = false
        Camera.applyBluetoothHighQualityRecordingPolicy(to: session, configuration: self.configuration(audio: true, isRoundVideo: true))
        XCTAssertTrue(session.configuresApplicationAudioSessionForBluetoothHighQualityRecording)
    }
}
