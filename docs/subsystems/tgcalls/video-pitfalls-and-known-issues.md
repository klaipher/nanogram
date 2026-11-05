# tgcalls: video support pitfalls and known issues

## Video Support Pitfalls

Critical findings from implementing video in the test SFU — relevant for anyone working on group video:

### H264 Decoder Requires Two Build Flags
The WebRTC BUILD needs BOTH `-DWEBRTC_USE_H264` (encoder, OpenH264) AND `-DWEBRTC_USE_H264_DECODER` (decoder, FFmpeg). Without the decoder flag, `H264Decoder::Create()` returns nullptr and WebRTC silently falls back to `NullVideoDecoder` which accepts frames but never decodes them — no error logged. The encoder works fine without the decoder flag, making this easy to miss.

### FFmpeg 7+ Removed `reordered_opaque`
`h264_decoder_impl.cc` uses `AVCodecContext::reordered_opaque` and `AVFrame::reordered_opaque` for passing timestamps through the decode pipeline. FFmpeg 7+ removed this field. The fix uses `AVPacket::pts` instead. IMPORTANT: `AVCodecContext::opaque` is already used to store the `H264DecoderImpl*` pointer (line 74 of `AVGetBuffer2`) — do NOT use it for timestamps.

### Outgoing Video Channel Steals Incoming RTP
`GroupInstanceCustomImpl` creates separate `cricket::VideoChannel` objects for outgoing and incoming video, all sharing the same `RtpTransport`. The outgoing channel's `WebRtcVideoReceiveChannel` has an "unsignalled SSRC" handler that creates default receive streams for unknown SSRCs. When video RTP from other participants arrives before `IncomingVideoChannel` registers its SSRCs, the outgoing channel intercepts the packets permanently. Fix: enable the `WebRTC-Video-DiscardPacketsWithUnknownSsrc` field trial in the field trial string.

### Video Channel Setup Is Reactive, Not Pre-Registered
Video channels are set up reactively when `ActiveVideoSsrcs` arrives via the data channel — same as the real Telegram app. The `dataChannelMessageReceived` callback in `GroupInstanceDescriptor` forwards Colibri messages to the app, which calls `setRequestedVideoChannels`. The `DiscardPacketsWithUnknownSsrc` field trial prevents the outgoing channel from stealing RTP packets for SSRCs not yet registered. The SFU sends proactive PLI after constraints arrive, ensuring keyframes are produced after the incoming channel is ready.

### SFU Must Send Proactive PLI
WebRTC's `VideoReceiveStream2` doesn't immediately request a keyframe when a new receive stream is created — it waits until it detects missing packets or a timeout. The SFU must proactively send PLI to the sender when a receiver first requests video via `ReceiverVideoConstraints`. Without this, the decoder waits indefinitely for a keyframe.

### RTP/RTCP Demux: Marker Bit False Positives
RFC 5761 demux by second byte: RTCP types are 200-211. But RTP with Marker=1 and dynamic PT ≥ 96 gives byte[1] ≥ 224. Using `byte[1] >= 200` falsely classifies H264 RTP (PT=104, M=1 → byte[1]=232) as RTCP. Correct range: `byte[1] >= 200 && byte[1] < 224`.

### SRTCP Requires Separate Contexts from SRTP
Pion's `SessionSRTP` and `SessionSRTCP` can't share the same `net.Conn` (both start read loops that fight for packets). The solution: demux RTCP at the transport level (in `PacketDemux`), create separate `srtp.Context` instances for SRTCP decrypt/encrypt using the same DTLS-extracted keys, and handle RTCP manually without `SessionSRTCP`.

### PeerConnection Simulcast SSRCs Require SDP Munging
PeerConnection's API doesn't support SSRC-based simulcast (only RID-based). With RID-based simulcast, SSRCs are NOT in the `createOffer` SDP — they're generated internally during `SetLocalDescription` and not accessible via `sender->GetParameters()` (only primary SSRCs, not RTX). The workaround: add a single-encoding transceiver (no RIDs), then replace the auto-generated `StreamParams` in the offer with pre-allocated SSRCs + SIM + FID groups before calling `SetLocalDescription`. `UpdateLocalStreams_w()` skips generation when SSRCs already exist. IMPORTANT: `transceiver->mid()` is `nullopt` before `SetLocalDescription` — match by content direction, not mid.

### MID RTP Header Extension Causes Wrong Channel Routing in SFU
The SFU forwards raw RTP packets including all header extensions. If the sender's video RTP includes a MID extension (e.g., MID="1"), the receiver's PeerConnection BUNDLE demuxer routes the packet to its own mid=1 channel — which is the outgoing video, not the incoming video transceiver. Fix: exclude `urn:ietf:params:rtp-hdrext:sdes:mid` from ALL m-lines in `buildRemoteAnswer()`. Without MID negotiated, PeerConnection falls back to SSRC/PT-based routing. This must be done for ALL m-lines (including audio) because the BUNDLE transport shares the extension map across all channels.

### `DiscardPacketsWithUnknownSsrc` Is Process-Wide
CustomImpl calls `field_trial::InitFieldTrialsFromString(...)` which sets `WebRTC-Video-DiscardPacketsWithUnknownSsrc/Enabled/` globally for the process. In mixed groups, this prevents ReferenceImpl's PeerConnection from creating unsignaled receive streams for incoming video. Fix: include explicit remote video SSRCs in the `buildRemoteAnswer()` for incoming video m-lines, so PeerConnection registers SSRC-based demux entries instead of relying on unsignaled stream handling.

### `OnTrack` Doesn't Fire for Locally-Created Recvonly Transceivers
When you call `AddTransceiver(MEDIA_TYPE_VIDEO, {direction=recvonly})`, PeerConnection creates the transceiver and its receiver track immediately. `OnTrack` only fires when a REMOTE-initiated track is added. For locally-created recvonly transceivers, you must wire sinks explicitly after `SetRemoteDescription` completes — don't wait for `OnTrack`.

### SSRC Parsing: json11 int_value() Overflows for uint32 > INT_MAX
`GoSfu_QueryVideoSsrcs` returns SSRCs as `uint32` in JSON. For values > 2^31, json11's `int_value()` (which returns `int`) overflows to `INT_MAX` (2147483647). Fix: use `number_value()` (returns `double`) and cast via `int64_t` to `uint32_t`.

### Join Payload JSON Field Name: `"sources"` Not `"ssrcs"`
tgcalls serializes video SSRC groups in `GroupJoinInternalPayload::serialize()` using the key `"sources"` (not `"ssrcs"`). The Go SFU's JSON struct tags must match: `Sources []int32 \`json:"sources"\``.

### Simulcast Max Layers Depends on Source Resolution, Not Bitrate
WebRTC's `kSimulcastFormats` table in `video/config/simulcast.cc` hardcodes `max_layers` per resolution: 640x360 → 2 layers, 960x540 → 3 layers, 1280x720 → 3 layers. The `SimulcastEncoderAdapter` uses this to cap the number of encoders regardless of available bitrate. If you need 3 simulcast layers, the source must be at least 960x540. The `FakeVideoTrackSource` uses 1280x720 for this reason. With 1280x720 and scale factors /4, /2, /1, the layers are 320x180, 640x360, 1280x720.

### SFU Must Rewrite SSRCs When Switching Simulcast Layers
CustomImpl's `IncomingVideoChannel` calls `SetSink(_mainVideoSsrc, ...)` where `_mainVideoSsrc` is the first SSRC in the SIM group (layer 0). The video sink only receives decoded frames from that specific SSRC's receive stream. When the SFU forwards a higher layer's packets, it must rewrite bytes 8-11 of the RTP header to the primary (layer 0) SSRC. RTX packets must similarly be rewritten to the layer 0 FID SSRC. Without this, higher-layer packets are delivered to the wrong receive stream and produce zero decoded frames. This is standard SFU behavior for simulcast — Jitsi and mediasoup do the same.

### Sender BWE Start Bitrate Determines Initial Layer Count
`adjustBitratePreferences` sets `start_bitrate_bps = max(min_bitrate_bps, 400k)`. At 400kbps start, the `BitrateAllocator` gives L0 (60k) + L1 (110k) = 170k, leaving only 230k for L2 which needs min 300k. Layer 2 is disabled until the GCC ramps up. The SFU's transport-cc feedback enables this ramp-up. The `UpdateAllocationLimits` log shows `total_requested_max_bitrate` — if this is below the sum of all layers' min bitrates, some layers are excluded.

### `assignPayloadTypes` Codec Ordering
WebRTC's `assignPayloadTypes` assigns dynamic PTs starting at 100 in order: VP8 (100/101), VP9 (102/103), H264 (104/105). Both sender and receiver call this independently with the same codec list, so PTs match. The SFU's join response codec PTs (100 for H264 in our case) are used by `configureVideoParams` to SELECT which codec to use, but the actual PT assignment comes from `assignPayloadTypes`.

## Known Issues
- `ThreadLocalObject::~ThreadLocalObject()` posts fire-and-forget cleanup tasks to the tgcalls media thread. If the process does orderly static destruction, the static thread pool may be torn down while these tasks are still executing, causing "pure virtual function called". The CLI tool uses `_exit()` to avoid this. This is not a problem in the real Telegram app.
- `SignalingSctpConnection::OnReadyToSend()` had a missing `break` after the first send failure in its pending-data flush loop. This could cause application-level message reordering (though the application handles it gracefully via `_pendingIceCandidates` buffering). Fixed in our fork.
- `InstanceV2ReferenceImpl::writeStateLogRecords()` had a use-after-free: it captured a raw `Call*` pointer on the media thread and posted it to the worker thread. If `stop()` called `_peerConnection->Close()` (which destroys `Call`) between the post and worker thread execution, the worker thread would dereference a dangling pointer. The `call_ptr_` field in WebRTC's `PeerConnection` is `Call* const` and is never nulled, so the existing null check didn't catch this. Fixed with an `_isStopped` atomic flag checked in the worker thread lambda before accessing `call`. Manifested as ~2% segfault rate under 250-process parallel load; 100% pass rate after fix (5000/5000).
- WebRTC's `RTC_LOG` writes to stdout, not stderr. There is no way to separate it from application output within a single process. The local mass test harness (`run-local-test.sh`) works around this by using separate processes and checking exit codes rather than parsing output.
