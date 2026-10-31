import XCTest
import TelegramAudio

/// The session type a voice-message recording asks for is derived from the Data & Storage
/// "Pause Music While Recording" toggle (bugs.telegram.org/c/24902). Whether the resulting
/// session mixes with other apps' audio is decided entirely by `withOthers`.
final class ManagedAudioSessionTypeTests: XCTestCase {
    func testVoiceMessageRecordingPausesOtherAudioWhenToggleIsOn() {
        let type = ManagedAudioSessionType.voiceMessageRecording(beginWithTone: false, pauseMusicOnRecording: true)
        XCTAssertEqual(type, .record(speaker: false, video: false, withOthers: false))
    }

    func testVoiceMessageRecordingMixesWithOtherAudioWhenToggleIsOff() {
        let type = ManagedAudioSessionType.voiceMessageRecording(beginWithTone: false, pauseMusicOnRecording: false)
        XCTAssertEqual(type, .record(speaker: false, video: false, withOthers: true))
    }

    func testVoiceMessageRecordingKeepsSpeakerForToneRegardlessOfToggle() {
        XCTAssertEqual(
            ManagedAudioSessionType.voiceMessageRecording(beginWithTone: true, pauseMusicOnRecording: true),
            .record(speaker: true, video: false, withOthers: false)
        )
        XCTAssertEqual(
            ManagedAudioSessionType.voiceMessageRecording(beginWithTone: true, pauseMusicOnRecording: false),
            .record(speaker: true, video: false, withOthers: true)
        )
    }

    /// Voice (and round-video) message recording asks for full-bandwidth Bluetooth recording on
    /// iOS 26+, so AirPods with support record full-band instead of narrowband HFP.
    func testVoiceMessageRecordingUsesBluetoothHighQualityRecordingForEveryToggle() {
        for beginWithTone in [false, true] {
            for pauseMusicOnRecording in [false, true] {
                let type = ManagedAudioSessionType.voiceMessageRecording(beginWithTone: beginWithTone, pauseMusicOnRecording: pauseMusicOnRecording)
                XCTAssertTrue(type.usesBluetoothHighQualityRecording, "beginWithTone=\(beginWithTone) pauseMusicOnRecording=\(pauseMusicOnRecording)")
            }
        }
    }

    /// The option is compatible only with mode .default and adds input latency, so video recording
    /// (.videoRecording mode), calls and playback never ask for it.
    func testOnlyNonVideoRecordingUsesBluetoothHighQualityRecording() {
        XCTAssertFalse(ManagedAudioSessionType.record(speaker: false, video: true, withOthers: true).usesBluetoothHighQualityRecording)
        XCTAssertFalse(ManagedAudioSessionType.voiceCall.usesBluetoothHighQualityRecording)
        XCTAssertFalse(ManagedAudioSessionType.videoCall.usesBluetoothHighQualityRecording)
        XCTAssertFalse(ManagedAudioSessionType.play(mixWithOthers: false).usesBluetoothHighQualityRecording)
        XCTAssertFalse(ManagedAudioSessionType.playWithPossiblePortOverride.usesBluetoothHighQualityRecording)
        XCTAssertFalse(ManagedAudioSessionType.ambient.usesBluetoothHighQualityRecording)
    }
}
