# tgcalls: macOS and Linux build support, vendored WebRTC seams

## macOS Build Support

This repo has been patched to support native macOS arm64 builds (`darwin_arm64` CPU) in addition to the original iOS targets. Changes made:
- `third-party/webrtc/BUILD` — added `@platforms//os:linux` to `arch_specific_cflags` select (fixes macOS getting Linux flags via `//conditions:default`); moved `cocoa_threading.mm` from `cc_library` to `webrtc_platform_helpers` `objc_library` (Bazel 8 rejects `.mm` in `cc_library`); replaced UIKit with AppKit for macOS
- `third-party/openh264/BUILD` — added `//conditions:default` to `select()` statements
- `third-party/webrtc/absl/absl/base/attributes.h` — disabled `ABSL_ATTRIBUTE_LIFETIME_BOUND` (newer Xcode clang rejects it on void-returning functions)

### Vendored webrtc seams for tgcalls (no behaviour patches)

The fork carries five additive seams, each marked
`TGCALLS SEAM (<consumer>)` in the source. None changes behaviour for a caller
that does not opt in. When bumping webrtc, carry these forward, and drop one
the moment upstream grows an equivalent.

| Seam | Where | Consumer |
|---|---|---|
| `PeerConnectionDependencies::dtls_transport_factory` | `api/peer_connection_interface.h`, `pc/peer_connection.{h,cc}` (plumbed to the `JsepTransportController::Config` field that already existed) | `tgcalls::MtProtoDtlsTransportFactory` |
| `PeerConnectionFactoryInterface::Options::external_transport_security` | `api/peer_connection_interface.h`; `pc/peer_connection.cc` in `InitializeTransportController_n` (`config.disable_encryption`) and `SrtpRequired()` | `InstanceV2ReferenceImpl`, `CallCoreHost` under `network_use_mtproto` |
| `PeerConnectionObserver::OnUnDemuxableRtpPacket(const RtpPacketReceived&)` | `api/peer_connection_interface.h`; `pc/peer_connection.cc` in `InitializeUnDemuxablePacketHandler` (network thread, before the hand-off to `Call`) | `GroupInstanceReferenceImpl` late-speaker SSRC discovery |
| `RTCConfiguration::disable_payload_type_demuxing` | `api/peer_connection_interface.h`; `pc/peer_connection.cc` (equality struct); read in `SdpOfferAnswerHandler::UpdatePayloadTypeDemuxingState` in `pc/sdp_offer_answer.cc` | `GroupInstanceReferenceImpl` (2026-09-19): with the MID extension stripped from the answer, stock WebRTC routes unknown SSRCs by payload type to whichever audio m-line is the only receiving one, creating unsignaled receive streams there; this engine signals every SSRC and discovers new ones from the dropped packets, so it opts out |
| `PeerConnectionSdpMethods::ResetSctpDataMidAfterRollback()` | `pc/peer_connection_internal.h`, `pc/peer_connection.{h,cc}`; called from `SdpOfferAnswerHandler::Rollback` in `pc/sdp_offer_answer.cc` | every PeerConnection engine, no opt-in — the one seam that changes stock behaviour, and only in a state stock never recovers from (below) |

The rollback seam (2026-09-17) closes a wedge that stock WebRTC cannot leave:
when the description that first set up the data-channel transport is rolled
back by a colliding remote offer, `sctp_mid` keeps naming an m-section no
stable description has (and which the remote offer may reuse for media).
`CheckIfNegotiationIsNeeded` then returns true forever for the missing data
section while `GetOptionsForUnifiedPlanOffer` never adds one because the mid is
set — an offer/answer loop for the rest of the call, one round per signaling
RTT, stopping the video send stream twice and flapping the audio channel each
round. The seam releases the mid (signaling- and network-side, without closing
the channels, so `HasDataChannels()` stays true) and the next offer renegotiates
data under a fresh mid. Production hit it in every 18/19 video call
(`getlogstgcalls/analysis/FINDINGS-v19-video-loop.md`); the engine-side cause
is fixed too (see `tgcalls/v2wasm/CLAUDE.md`), this seam is the backstop for any
future start glare. Reproduce/verify with the CLI: `tgcalls_cli --mode p2p
--version 19.0.0 --version2 19.0.0 --video` must show 4 description sets per
call and one `Creating data channel`.

History, so nobody reintroduces them: between 2026-09-01 and 2026-09-16 the
fork carried three *behaviour* patches instead ("Allow SCTP without DTLS" in
`pc/peer_connection.cc` and `pc/media_session.cc`, "Inactive DtlsTransport
forwards packet flags" in `p2p/base/dtls_transport.cc`), all consequences of
using `Options::disable_encryption` for mtproto. Engine-side detail and the
regression they caused are in `tgcalls/CLAUDE.md` under "mtproto transport on
the PeerConnection engines"; the design record is
`docs/superpowers/specs/2026-09-16-tgcalls-mtproto-dtls-slot-design.md`.

- 8 third-party BUILD files + 8 build shell scripts — added `darwin_arm64 -> macos_arm64` architecture support (opus, libvpx, ffmpeg, dav1d, mozjpeg, webp, libjxl, td)

## Linux Build Support

The repo supports native Linux arm64 and x86_64 builds. Key changes from the iOS/macOS-only baseline:
- `.bazelrc` — Apple toolchain settings under `build:macos`, Linux uses default CC toolchain via `build:linux` (auto-selected by `--enable_platform_specific_config`)
- `build-system/BUILD` — `linux_arm64` and `linux_x86_64` config_settings
- `objc_library` → `cc_library` conversions for pure C/C++ targets (ogg, opusfile, rnnoise, opus, libvpx, dav1d, ffmpeg wrappers, WebRTC main target)
- WebRTC BUILD — platform flags via `select()` (`-DWEBRTC_LINUX` vs `-DWEBRTC_MAC`), stdlib task queue instead of GCD on Linux, macOS-only sources excluded
- Third-party genrule build scripts — Linux architecture cases added (libvpx, dav1d, ffmpeg), system cmake/meson/ninja used instead of downloaded macOS binaries
- BoringSSL — `_Generic` C11 guarded for C++ mode (GCC compatibility)
- tgcalls headers — `#include <cstdint>` added for GCC 15 strictness
