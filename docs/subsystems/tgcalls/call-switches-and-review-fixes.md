# tgcalls: local call switches (batches A and B) and review fixes

## Local call-video switches (Batch A, 2026-11)

Three Debug Settings switches reach tgcalls through `tgcalls::CallsRuntimeSwitches` (process-wide atomics,
`tgcalls/CallsRuntimeSwitches.h`), set from `PresentationCallManagerImpl` via
`OngoingCallContext.applyVideoExperiments` whenever the setting changes. All default OFF, none touches the wire
(no SDP, signalling, negotiation or codec-list change), and each falls back to the old path at runtime:

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
**Shared tgcalls code: every commit here must also reach the Mac branch (`nanogram-mac-integration`); use `tools/dev/tgcalls-port` (see the repo CLAUDE.md, "Shared tgcalls code").**

## Local call-audio switches (Batch B, 2026-11)

Four more Debug Settings switches, same path (`CallsRuntimeSwitches`, `OngoingCallContext.applyAudioExperiments`), same
rules: local only, nothing on the wire. Decisions are in `tgcalls/AudioCallPolicy.h` (host test `audio_call_policy_test`).

- **`callsSystemNoiseSuppression`** (OFF): on iOS the call microphone runs on VoiceProcessingIO, which already does AEC,
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
- **`callsGroupNarrowbandProcessing`** (OFF): group calls on 8/16 kHz capture (Bluetooth HFP) keep the RNNoise result and the
  external-audio mix. Before the Mac `a598e27` cherry-pick the narrowband result was discarded, so keeping it is a new
  audio path and is gated (`GroupAudioCapturePostProcessor.cpp`). While on, every frame goes through both resamplers when
  noise suppression is enabled, including the quiet frames RNNoise skips, so the delay is constant and the resampler
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
comes from a peak detector and RNNoise does not run; `tests/group_audio/run.sh` needs `libtg_owt.a` from the Mac checkout.

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
