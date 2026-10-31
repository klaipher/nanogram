import Foundation
import AVFoundation

public extension Camera.Configuration {
    /// Whether the capture session records from AirPods (and other routes that support it) with
    /// full-bandwidth Bluetooth audio instead of narrowband HFP, on iOS 26+.
    ///
    /// Only round videos qualify: they record under the app's `.record(video: false)` audio session
    /// (mode `.default`), which already asks for `.bluetoothHighQualityRecording`. Other captures
    /// (stories, the attachment camera) record under `.videoRecording`, a mode the option is not
    /// compatible with.
    var capturesBluetoothHighQualityAudio: Bool {
        return self.audio && self.isRoundVideo
    }
}

public extension Camera {
    /// Applies the configuration's Bluetooth high-quality recording opt-in to a capture session.
    ///
    /// The app's audio session category option is not enough on its own: `AVCaptureSession` sends
    /// its own opt-in to the capture server, and its audio device keeps an auxiliary session that
    /// excludes high-quality Bluetooth routes unless the session opts in (both independent of
    /// `automaticallyConfiguresApplicationAudioSession`, which stays `false` here, so the app's
    /// audio session is still left alone). No change below iOS 26 or without a capable route.
    static func applyBluetoothHighQualityRecordingPolicy(to session: AVCaptureSession, configuration: Camera.Configuration) {
        #if canImport(AlarmKit) //Xcode 26
        if #available(iOS 26.0, *) {
            let value = configuration.capturesBluetoothHighQualityAudio
            if session.configuresApplicationAudioSessionForBluetoothHighQualityRecording != value {
                session.configuresApplicationAudioSessionForBluetoothHighQualityRecording = value
            }
        }
        #endif
    }
}
