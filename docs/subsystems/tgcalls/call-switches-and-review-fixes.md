# tgcalls: local call switches (batches A and B) and review fixes

## Local call-video switches (Batch A, 2026-11)

Three Debug Settings switches reach tgcalls through `tgcalls::CallsRuntimeSwitches` (process-wide atomics,
`tgcalls/CallsRuntimeSwitches.h`), set from `PresentationCallManagerImpl` via
`OngoingCallContext.applyVideoExperiments` whenever the setting changes. Defaults: see "Defaults since 2026-11-06"
below (the engine's own atomics start OFF; the app sets them from the settings, which default ON). None touches the
wire (no SDP, signalling, negotiation or codec-list change), and each falls back to the old path at runtime:

- **`callsLivestreamHardwareDecoding`**: live stream video decodes with VideoToolbox (`DarwinFFMpeg.mm`,
  `PlatformInterface::setupHardwareVideoDecoding`). `group/LivestreamDecodePolicy.h` holds the decisions (eligibility:
  8-bit 4:2:0 H.264/HEVC, progressive, at most 4096; a 2-session process cap; per-stream "hardware failed" latch;
  pruning of per-endpoint decoder state). `get_format` must return VideoToolbox only when FFmpeg offers it and
  otherwise `avcodec_default_get_format`: answering a format that is not in the list blacks the stream out (the
  same bug the main app fixed in `FFMpegAVCodecContext.m`). A hardware error ends the current part and the stream
  decodes in software from the next one. One log line per decoder: `livestream decode: hardware|software (reason) ...`.
  The simulator has no usable hwaccel; `TARGET_OS_SIMULATOR` keeps it software.
- **`callsNativeCapturePath`**: camera NV12 pixel buffers reach the encoder as `ObjCFrameBuffer(TGRTCCVPixelBuffer)`
  instead of being converted to I420 (`VideoCameraCapturer.mm`, `DarwinVideoSource.mm` builds the adapted
  `RTCCVPixelBuffer`). Decisions in `platform/darwin/CaptureFramePolicy.h`: a paused camera drops the frame before any
  crop or conversion (this part is always on, it only removes wasted work); a burst of `OutOfBuffers` drops latches the
  capture back to I420; the camera runs at the adapter's 25 fps when its format allows. The switch is read when a capture
  starts, so toggling it applies to the next camera start. Colour: native frames keep the camera's real range tag
  (`420v`), where the I420 copy re-labelled video-range data as full range, so the picture may look slightly different.
- **`callsEncoderLowLatency`**: iOS 14.5+ `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` plus
  `RealTime=true` in `TGRTCVideoEncoderH264.mm` (`platform/darwin/EncoderModePolicy.h`). Session creation failure, or
  the negotiated profile not applying in that mode, rebuilds the standard session and latches low-latency off for the
  process. HEVC and the Mac encoders are unchanged.

Host tests for the pure policies are header-only `cc_test`s declared with `policy_cc_test` (`policy_test.bzl`, builds in
seconds, no tgcalls_core): `livestream_decode_policy_test`, `capture_frame_policy_test`, `encoder_mode_policy_test`,
`video_plane_layout_test`. Their `.cpp` files have a `main()`, so they are in `tgcalls/Package.swift`'s exclude list.
**Shared tgcalls code: one branch (`nanogram-shared`) serves iOS, Mac and Android; a fix is one fork commit and the three pins move to it (see `docs/subsystems/tgcalls.md`, "Shared tgcalls code").**

## Local call-audio switches (Batch B, 2026-11)

Four more Debug Settings switches, same path (`CallsRuntimeSwitches`, `OngoingCallContext.applyAudioExperiments`), same
rules: local only, nothing on the wire. Decisions are in `tgcalls/AudioCallPolicy.h` (host test `audio_call_policy_test`).

- **`callsSystemNoiseSuppression`** (ON since 2026-11-06): on iOS the call microphone runs on VoiceProcessingIO, which already does AEC,
  noise suppression and AGC. With the switch on, `chooseCaptureProcessing` drops WebRTC's `noise_suppression` and
  `highpass_filter` from the outgoing audio options in v2 (`InstanceV2Impl.cpp`), legacy (`MediaManager.cpp`) and group
  (`GroupInstanceCustomImpl.cpp`, only when the participant has audio input). Software stays for RemoteIO (listeners,
  streams), bypass, macOS, and after `SystemVoiceProcessingLatch::markFailed()` (set by the audio unit when VoiceProcessingIO
  cannot be created, initialised, or bypass is requested). Echo cancellation is not touched. One log line per channel.
  Options are read when the channel is created, so the switch applies from the next call.
- **`callsAdvancedDucking`** (OFF since the review of 2026-11-04; it first shipped ON without device evidence, and with
  `.mixWithOthers` the other app's audio stays near full level between sentences with no echo reference, so it may reach
  the peer; the setting is stored under a new key so old `true` values do not turn it on): iOS 17+ `kAUVoiceIOProperty_OtherAudioDuckingConfiguration`, advanced ducking at the
  minimum level (`VoiceProcessingAudioUnit::ConfigureOtherAudioDucking`). A failure keeps the system default.
- **`callsGroupNarrowbandProcessing`** (removed, always on; there is no switch and no setting): group calls on 8/16 kHz capture (Bluetooth HFP) keep the RNNoise result and the
  external-audio mix. Before the Mac `a598e27` cherry-pick the narrowband result was discarded; keeping it is now
  unconditional (`GroupAudioCapturePostProcessor.cpp`), which is what lets "RNNoise only" still suppress noise on a
  Bluetooth HFP microphone. While noise suppression is enabled, every frame goes through both resamplers,
  including the quiet frames RNNoise skips, so the delay is constant and the resampler
  history never goes stale.
- The former **`callsOpusFirstLossFloor`** switch was removed: `WebRTC-Audio-OpusMinPacketLossRate` is read nowhere in
  `third-party/webrtc` (the same string in `GroupInstanceCustomImpl.cpp` and `MediaManager.cpp` is upstream and equally dead),
  so the switch changed nothing. Do not re-add it without a real encoder-side floor (`SetProjectedPacketLossRate`).
- The former **`callsKeepSessionMode`** switch was removed with its code (owner decision, 2026-11-04):
  `RTCAudioSession+Configuration.mm` is upstream again, so the engine's voiceChat mode is applied as before. Thread
  priorities (QoS), the 32 kHz processing rate, the Opus complexity and the Mac audio workgroup were removed the same
  way. Do not re-add them as switches.

**A voice-processing failure after the options were chosen** (`SoftwareNoiseSuppressionFallback.h`): the channel drops
the software stage before the audio unit starts, so a unit that then fails would leave that call with no noise suppression
at all. `SystemVoiceProcessingLatch` now notifies observers on the first failure; each channel that dropped the software
stage holds a `SoftwareNoiseSuppressionFallback` that re-enables `noise_suppression` (level high) in the live audio
processing module on the worker thread. Its destructor waits for the worker so no task touches the audio state afterwards.
Note `highpass_filter = false` saves nothing while echo cancellation is on (the canceller keeps the filter) and v2/group
already lose it through `WebRTC-Audio-MinimizeResamplingOnMobile`.

Group-call RNNoise gating (Mac a598e27) is cherry-picked unchanged: with noise suppression off the speaking indicator
comes from a peak detector and RNNoise does not run; `tests/group_audio/run.sh` needs the WebRTC static library from the Mac build.

## Review fixes of the call work (2026-11-04)

- **Low-latency encoder failures after the session exists** (`EncoderModePolicy.h`, `LowLatencyFailureTracker`): a
  malfunction or an asynchronous encode error of a low-latency session latches low-latency off for the process and the next
  frame rebuilds the standard session; an invalid session (normal after a background trip) only counts when it repeats three
  times without an encoded frame between.
- **Livestream catch-up and skipped parts** (`StreamRenderPolicy.h`): a tile shown again mid-part decodes at most
  `kMaxStreamFramesDecodedPerTick` (6) frames per render tick instead of everything up to "now" in one call (it stalled the
  media thread and the audio refill). The "each part starts on a keyframe" assumption is the code's own invariant: the decoder
  is flushed after every part (`VideoStreamingSharedStateInternal::reset`). A skipped part never reaches that flush, so
  `SkippedPartFlag` flushes the decoder once before it is used again.
- **Camera crop on the native path** (`CaptureFramePolicy.h`, `planCameraCrop`): with an aspect crop active the native path
  no longer copies into an unpooled `CVPixelBufferCreate` buffer per frame; the frame keeps the camera buffer and the crop
  rectangle and the encoder crops once into its IOSurface pool. The I420 path is unchanged.
- **Thermal ladder reaches the camera** (`CallPowerPolicy.h`, `thermalCameraFpsCap`; `VideoCapturerInterface::setMaximumFrameRate`):
  from level 2 the camera runs at the ladder's 20/15 fps instead of only the adapter dropping frames (uneven at 30 to 20).
  Group video calls bind the governor too (`PresentationGroupCall`). Low Power Mode alone is level 1 and changes nothing.
- **Thread QoS** was removed (owner decision, 2026-11-04): the engine threads keep the system default class
  (`StaticThreads.cpp` is upstream).

## Defaults since 2026-11-06 (owner decision)

On iOS these start ON, and stay switchable in Debug Settings ▸ Streams & Calls: `callsLivestreamHardwareDecoding`,
`callsNativeCapturePath`, `callsSystemNoiseSuppression`, `callsThermalVideoLadder`, and `callsGroupNoiseMode` = 2
(RNNoise only; narrowband processing is always on, so a Bluetooth HFP microphone is still suppressed). Not turned on:
`callsAdvancedDucking` (other apps' audio may reach the peer), the group reference engine, VoIP TCP, on-device translation.

`ExperimentalUISettings` is saved as a whole struct, so an install that ever saved it holds an explicit `false` (and
group noise mode 0) under the old keys without having chosen it. Each changed setting therefore moved to a new key
(`...DefaultOn`, `callsGroupNoiseModeRNNoiseDefault`), as advanced ducking did (`callsAdvancedDuckingOptIn`): the old
keys are no longer read or written, so only a choice made after this change counts. Tests: `CallsSwitchesTests`.
The tgcalls engine itself still starts with every atomic OFF; `PresentationCallManager` sets them from the settings
(whose defaults are ON) before the first call. The Mac pins the same core: its own Debug Settings and defaults are
separate and unchanged until the Mac lane decides (shared/feature-parity.md has the row).

## Audio route requests (speaker toggle), 2026-11-06

Report: on one iPhone 14 the speaker button did nothing. No log, so the cause is not proven; what the code showed:

- **The request was dropped when it equalled the stored value** (`PresentationCall.setCurrentAudioOutput`,
  `SharedCallAudioContext.setCurrentAudioOutput`, the non-shared `PresentationGroupCall` path). The stored value is set the
  moment the user taps, before the session has done anything, and `ManagedAudioSession` reports a route only when it
  changed. How long that blocks depends on the path (review correction):
  - Default path (`SharedCallAudioContext`, used by 1:1 and group calls unless a killswitch is set): the optimistic value
    is followed one second later by the last reported route, and `audioOutputStateDisposable` copies it back into the
    stored value. So a request that had no effect blocks only a second tap within that second; the next tap is sent again.
    On this path "the button does nothing" means the requests reach the session and the session does not honour them,
    which is what the new `MISSED` line shows.
  - Non-shared paths (`ios_killswitch_disable_call_device` for 1:1, `ios_killswitch_group_shared_audio` for group calls):
    the stored value changes only on a route report, so one ineffective request blocked every later tap for the same route
    for the rest of the call.
  Now `audioOutputRequestDecision` (`AudioOutputRequestPolicy.swift`) skips a request only when the session itself reports
  that route, on all three paths.
- **CallKit gave the session back without the override** after an interruption (`didDeactivate`, `didActivate`); only a
  request that arrived while the session was inactive was applied again. `CallKitProviderDelegate` now puts the
  loudspeaker back on `didActivate` when the last request was the loudspeaker and the route is still the phone's own
  (`loudspeakerShouldBeReappliedOnActivation`). Review correction: the first version re-applied any last mode, which would
  have pinned the built-in microphone or a stale port over AirPods or a car that connected after the request.
- A request made while CallKit has not activated the session waits for `didActivate`; that is now logged
  (`audio output request waits for CallKit to activate the session`), so a `didActivate` that never comes shows in the log.
- **The built-in-microphone test hid a loudspeaker route** (`ManagedAudioSession.updateCurrentAudioRouteInfo`): the speaker
  was reported only when the built-in microphone was the active input. The route outputs now decide.
- The video call screen forces the speaker every second while the route is the receiver (upstream). It now gives up after
  three attempts (`AutomaticSpeakerEnforcement`) so a session that refuses does not get a request and a screen flash every second.
- **Diagnostics for the next report** (short log, no names): `audio output request <route> (last request, session reports,
  CallKit|direct): applying|skipped`, and after every apply `ManagedAudioSession output request ... -> route <headset|loudspeaker|receiver|other>
  outputs=[...]`, with `MISSED` when the loudspeaker was asked for and the route is not on it. `audioInputStateDescription` now also
  lists the route outputs, category, mode and options.

Hypotheses for that iPhone 14, most likely first (none proven): (1) the session does not honour
`overrideOutputAudioPort(.speaker)` because the category or mode was changed under the call (the audio device module's own
configuration; `scheduleSpeakerReapply` exists for the same race at call start); (2) with CallKit, the request waits for a
`didActivate` that came late or never; (3) an interruption (GSM call, Siri, alarm) cleared the override (now re-applied);
(4) the button is disabled because `availableInputs` was nil, so `availableOutputs` had one entry and `canSwitchAudioOutput`
is false (`CallControllerNodeV2.updateAudioOutputs`); (5) a car, AirPlay or unknown Bluetooth route owns the output;
(6) the stored-value latch, only if a killswitch put the call on a non-shared path.

Open without a recording from the phone: why the first request failed on that iPhone 14. The `MISSED` line plus the category, mode and
options in the line before it will say whether the category was changed under the call, the session was inactive, or a
Bluetooth / car / AirPlay route owned the output.

## Call controls audit (iOS, 2026-11-06)

Read from the action to the session, the engine call and back to the screen. Nothing was run on a device.

| Control | Result |
|---|---|
| Speaker / route, 1:1 and group (`setCurrentAudioOutput`) | Fixed: a request was dropped when equal to the stored value (see above; for a second on the default path, for the rest of the call on the killswitch paths). Group calls through `SharedCallAudioContext` get the same fix. |
| Route with Bluetooth, AirPods, wired, CarPlay | Read: more than two outputs open the route sheet, two outputs toggle. A headset in the route is never overridden by the speaker default (`resolveInitialOutput`, tests exist). CarPlay and AirPlay are not distinguished (they show as `.port` / headphones); not changed. Needs a device to judge. |
| Mute: button | OK. 1:1 `setIsMuted` reaches the engine or the conference; group `setIsMuted` also persists the choice and the server mute state. |
| Mute: CallKit (lock screen, Dynamic Island, system call UI, AirPods gesture, Siri) | Fixed: the handler passed `CXAction.uuid` (the action's id) instead of `callUUID`, so it matched no call. |
| Mute: app to CallKit | Fixed: an in-app mute was never reported, so the system UI showed the wrong state (`CallKitMuteSync`). The app's own action comes back to the provider; it is recognised by its action id and not applied a second time, so a quick mute-unmute is not undone by the late echo. A refused transaction restores what CallKit shows. |
| Mute: CallKit after 1:1 to conference | Fixed (review): the CallKit call stays under the 1:1 call's id, but the lock-screen mute went only to `currentCall`, which is nil after the upgrade, and the conference never reported its mute. `callKitMuteRecipient` routes the action to the 1:1 call object while it hands over and then to the conference (`conferenceSource`); `PresentationGroupCallImpl` reports its mute state for that id. A mute the server forbids (`canUnmute == false`) is not forced; the lock screen then shows unmuted until the next change. |
| Camera on/off, 1:1 | Fixed: cancelling the camera preview left the capturer (and the camera) held by the call until it ended. Every dismissal that is not a share counts, including the app going to the background, which dismisses the preview on its own (review). |
| Camera flip, 1:1 and group | Fixed: the flip belief was not reset when the camera went off and on, and not set when a capturer arrived on the back camera (video chat screen, 1:1 upgraded to a conference). The first flip did nothing (`CameraFacingTracker`). |
| Video pause | `setOutgoingVideoIsPaused` has no caller; a camera interrupted by the system is reported by the capturer's `isActive` and shown as paused. OK. |
| Screen broadcast start/stop | Start and stop are detected through the extension's keepalive file (`IpcGroupCallBufferAppContext`), so a stop from Control Center or the status bar pill is noticed after the keepalive timeout, not at once. Starting a broadcast turns the camera off and it is not restored when the broadcast ends (by design, unchanged). |
| PiP | The gate follows PiP activation and is reset in `deinit` of the call screen. OK. |
| Raise hand | `raiseHand` / `lowerHand` read the own participant's state first and are idempotent. OK. |
| Interruptions (GSM call, Siri) | `ManagedAudioSession` keeps the call holder on an interruption; resuming the audio unit is done by the engine (`AudioDeviceIOS::OnInterruptionEnd`). The loudspeaker override is lost on a CallKit reactivation: fixed (put back only on the phone's own route). |
| Call end cleanup | The audio holder is released with the context (`markCallFinished`, `retire`); the camera capturer is released with the call object, at least 2 s after the end. Not changed. |
| 1:1 to conference | Mute and video carry over; the camera side now carries over too (see the flip row). The speaker is switched on for the conference. |
| Reconnect | Engine state only (`.reconnecting` mapped to the screen); no control state is kept in the UI. OK. |
