# WebRTC CVEs fixed after our snapshot

Compiled 2026-11-02 for audit item #42 (Round J). Documentation only; nothing here changes code.

## Our WebRTC

- `third-party/webrtc/webrtc` (the tgcalls fork, one squashed commit) reports
  `WebRTC source stamp 2024-02-18T04:06:34` (`call/version.cc`). That is a main-branch snapshot
  taken one day before Chromium's M123 branch point (M122 branched 2024-01-22 and went stable
  2024-02-20; M123 branched 2024-02-19 and went stable 2024-03-19, per chromiumdash). So it has
  everything M122 shipped and roughly what M123 branched with, and none of the security fixes
  merged after 2024-02-18.
- What we compile (`third-party/webrtc/BUILD`): ICE/STUN/TURN (`p2p/`), DTLS-SRTP and the
  `PeerConnection` layer (`pc/`, including `webrtc_sdp.cc`), RTP/RTCP (99 files under
  `modules/rtp_rtcp/source`, with the VP8, VP9, H.264, H.265, AV1 and generic depacketizers),
  NetEq and the Opus/G.711/G.722/iLBC audio codecs, audio processing (AEC3, AGC2, NS), the video
  receive/send pipeline, and dcsctp (data channels). tgcalls uses data channels in 1:1 calls
  (`v2/CustomDcSctpSocket.h`, `SctpDataChannelProviderInterfaceImpl`) and group calls.
- Not affected by this list: the codec and crypto libraries WebRTC calls are separate,
  recently updated dependencies (libvpx 1.17.0, dav1d 1.5.4, openh264 2.7.0, BoringSSL of
  2026-10-30). A codec CVE such as libvpx's CVE-2025-5283 (fixed in 1.15.2) is covered by those
  updates, not by WebRTC. libsrtp, abseil and pffft live in the WebRTC tree and follow it.

## Who can reach it in Telegram

A browser's WebRTC is driven by the web page; tgcalls' is driven by our own code, so the usual
Chrome vector ("a crafted HTML page") does not exist here. What exists:

- **The other party of a 1:1 call** controls everything that arrives: RTP/RTCP, the encoded
  audio and video bitstreams, data-channel messages and the tgcalls signaling. Any user allowed
  to call you can start one.
- **Group-call participants**, through the SFU, which forwards their media.
- **Telegram's relays/SFU or a network attacker**: the media is encrypted (DTLS-SRTP, or the
  MTProto-keyed transport), so they reach the packet-parsing layers before decryption (STUN,
  DTLS, SRTP framing) but not the payload parsers.

So a fix in libwebrtc's media or transport code is plausibly reachable by a malicious caller.
A fix in Chromium's Blink bindings (`third_party/blink/renderer/modules/peerconnection`) or in
`content/` is not in our build at all.

## Method and its limit

Source: NVD (`services.nvd.nist.gov` CVE API 2.0, keyword "WebRTC", fetched 2026-11-02),
cross-checked against the Chrome Releases stable-channel posts it cites. Google's descriptions
say "in WebRTC" for both libwebrtc and its Blink glue, and the Chromium bugs stay restricted
until well after the fix, so **for most entries the public record does not say which side the
bug was in**. The "Relevance" column is therefore:

- **Likely**: the description says the attack comes over the network.
- **Possible**: Apple-platform code (shared with our iOS build through `sdk/objc`).
- **Unknown**: a memory-safety bug reached from a page; relevant if the fix is in libwebrtc.
- **Unlikely**: Windows- or Linux-only code.
- **Not applicable**: depends on the browser's process or origin model (compromised renderer
  or GPU process, cross-origin leaks).

Resolving the Unknowns means finding each fix in webrtc.googlesource.com (commit messages carry
`Bug: chromium:<id>`, and the bugs open up about 14 weeks after the fix).

CVE-2024-3170 (fixed in Chrome 121) and CVE-2023-7010 (Chrome 117) predate the snapshot and are
not listed.

## Chrome CVEs in WebRTC fixed after 2024-02-18

65 entries, Chrome 125 to 156.

| CVE | Fixed in Chrome | Kind | Severity | Attacker (NVD) | Relevance to tgcalls |
|---|---|---|---|---|---|
| CVE-2024-5493 | 125.0.6422.141 | Heap buffer overflow | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2024-10488 | 130.0.6723.92 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2025-7657 | 138.0.7204.157 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2025-10501 | 140.0.7339.185 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2025-13639 | 143.0.7499.41 | Inappropriate implementation | Low | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-4444 | 146.0.7680.153 | Stack buffer overflow | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-4445 | 146.0.7680.153 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-4446 | 146.0.7680.153 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-4463 | 146.0.7680.153 | Heap buffer overflow | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-5860 | 147.0.7727.55 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-5912 | 147.0.7727.55 | Integer overflow | Low | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-7336 | 147.0.7727.138 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-7339 | 147.0.7727.138 | Heap buffer overflow | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-7341 | 147.0.7727.138 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-7928 | 148.0.7778.96 (on Windows) | Use after free | High | crafted page | Unlikely: Windows-only code |
| CVE-2026-7951 | 148.0.7778.96 | Out of bounds write | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-7987 | 148.0.7778.96 | Use after free | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-7988 | 148.0.7778.96 | Type Confusion | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-8016 | 148.0.7778.96 | Use after free | Low | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-8526 | 148.0.7778.168 | Out of bounds write | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-9111 | 148.0.7778.179 (on Linux) | Use after free | Critical | crafted page | Unlikely: Linux-only code |
| CVE-2026-9119 | 148.0.7778.179 | Heap buffer overflow | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-9120 | 148.0.7778.179 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-9959 | 148.0.7778.216 (on Windows) | Race | High | crafted page | Unlikely: Windows-only code |
| CVE-2026-9962 | 148.0.7778.216 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-9988 | 148.0.7778.216 (on Linux) | Use after free | High | crafted page | Unlikely: Linux-only code |
| CVE-2026-9996 | 148.0.7778.216 (on Mac) | Out of bounds read | High | crafted page | Possible: Apple-platform code |
| CVE-2026-10903 | 149.0.7827.53 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-10939 | 149.0.7827.53 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-10943 | 149.0.7827.53 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-10947 | 149.0.7827.53 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-10948 | 149.0.7827.53 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-10975 | 149.0.7827.53 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-11003 | 149.0.7827.53 | Use after free | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-11054 | 149.0.7827.53 | Use after free | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-11074 | 149.0.7827.53 (on Linux) | Use after free | Medium | crafted page | Unlikely: Linux-only code |
| CVE-2026-11096 | 149.0.7827.53 | Out of bounds read | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-11118 | 149.0.7827.53 | Use after free | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-11199 | 149.0.7827.53 | Inappropriate implementation | Medium | network traffic | Not applicable: cross-origin leak in the browser |
| CVE-2026-11200 | 149.0.7827.53 | Inappropriate implementation | Medium | crafted page | Not applicable: browser process/origin model |
| CVE-2026-11667 | 149.0.7827.103 | Out of bounds read | High | compromised GPU process | Not applicable: browser process/origin model |
| CVE-2026-12447 | 149.0.7827.155 | Heap buffer overflow | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-12461 | 149.0.7827.155 (on Windows) | Out of bounds read | High | crafted page | Unlikely: Windows-only code |
| CVE-2026-12466 | 149.0.7827.155 (on Windows) | Heap buffer overflow | High | crafted page | Unlikely: Windows-only code |
| CVE-2026-14015 | 150.0.7871.47 (on Windows) | Race | Medium | crafted page | Unlikely: Windows-only code |
| CVE-2026-14078 | 150.0.7871.47 | Insufficient validation of untrusted input | Low | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-15121 | 150.0.7871.115 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-17884 | 151.0.7922.72 | Object lifecycle issue | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-17951 | 151.0.7922.72 | Heap buffer overflow | Low | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-78891 | 152.0.7977.65 | Buffer overflow | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-78950 | 152.0.7977.65 | Integer overflow | Low | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-79027 | 152.0.7977.65 | Use after free | High | network traffic | **Likely**: reachable from the network |
| CVE-2026-79187 | 152.0.7977.65 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-79255 | 152.0.7977.65 | Improper input validation | Medium | compromised renderer | Not applicable: browser process/origin model |
| CVE-2026-84347 | 152.0.7977.75 | Use after free | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-87430 | 153.0.8010.36 | Buffer overflow | Low | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-87579 | 153.0.8010.36 | Buffer overflow | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-87630 | 153.0.8010.36 | Integer overflow | Medium | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-103631 | 154.0.8037.97 | Buffer overflow | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-106268 | 155.0.8059.39 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-106357 | 155.0.8059.39 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-110137 | 155.0.8059.79 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-113161 | 156.0.8078.47 | Use after free | High | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-113303 | 156.0.8078.47 | Memory corruption | Critical | crafted page | Unknown: libwebrtc or Blink glue |
| CVE-2026-118328 | 156.0.8078.73 | Improper input validation | High | crafted page | Unknown: libwebrtc or Blink glue |

Counts: 1 Likely, 1 Possible, 51 Unknown, 8 Unlikely, 4 Not applicable.

## Firefox CVEs in WebRTC components

Mozilla's "WebRTC: Networking" (its own ICE stack, nICEr/mtransport) and "WebRTC: Signaling"
(its own JSEP) are not libwebrtc code, so CVE-2024-4764, CVE-2025-14321, CVE-2026-4704/4705/4718,
CVE-2026-6776, CVE-2026-7321, CVE-2026-109771, CVE-2026-117892/117894/117957, CVE-2026-118005/118006
do not apply. "WebRTC: Audio/Video" includes Firefox's use of libwebrtc's media pipeline, so
CVE-2025-13020, CVE-2026-2757, CVE-2026-8972, CVE-2026-16362 (and the unlabelled "WebRTC
component" ones: CVE-2026-6747/6752/6753/6775, CVE-2026-8094, CVE-2026-74958, CVE-2026-92045,
CVE-2026-109775, CVE-2026-117996) are in the same "Unknown" class as the Chrome entries.

## Assessment

- One CVE (CVE-2026-79027, use-after-free reachable "via crafted network traffic", Chrome 152,
  High) is very likely in code we ship and reachable by a call peer.
- 51 High/Medium/Low memory-safety fixes may or may not be in libwebrtc. Chrome shipped
  WebRTC fixes in every milestone from 146 to 156, several High; if even a few are in the RTP,
  depacketizer, NetEq or dcsctp code, a malicious caller can reach them in Telegram.
- Our snapshot is 2 years and 8 months behind (M123 vs M156 stable).

## Recommendation

1. Rebase the tgcalls WebRTC fork onto a current branch-head (M156) rather than cherry-picking:
   with 50+ candidate fixes across 2.7 years, finding and back-porting each is more work and
   less certain than a rebase. The fork is one squashed commit, so its local changes (the
   tgcalls seams, e.g. `RTCConfiguration::disable_payload_type_demuxing`) have to be found by
   diffing it against the upstream revision of 2024-02-18 first.
2. Until then, the cheapest mitigation is the one Telegram already has: calls from
   non-contacts can be restricted by the user's privacy settings, which narrows "any user"
   to contacts.
3. If a rebase is not scheduled soon, triage the Unknowns by locating each fix upstream and
   back-port those in `modules/rtp_rtcp`, `modules/audio_coding/neteq`, `net/dcsctp`, `p2p`
   and `pc/`.

Sources: NVD CVE API 2.0 (keyword WebRTC); Chrome Releases stable-channel updates
(chromereleases.googleblog.com) cited by each NVD entry; chromiumdash milestone schedule
(M122, M123); Mozilla Foundation Security Advisories cited by the Firefox entries.
