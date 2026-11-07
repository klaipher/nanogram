# tgcalls: InstanceV2CompatImpl

## InstanceV2CompatImpl (version 14.0.0)

A 13.0.0-protocol endpoint whose media engine is a WebRTC PeerConnection. It speaks `InstanceV2Impl`'s
signaling (`InitialSetupMessage`, `NegotiateChannelsMessage`, `CandidatesMessage`, `MediaStateMessage`)
so it interoperates with 7.0.0–13.0.0 and with itself. Rewritten 2026-10-11, when it carried
two-way media in no pairing (design record: telegram-ios
`docs/superpowers/specs/2026-10-11-tgcalls-compatimpl-v2-protocol-design.md`).

```
PeerConnection <-> SignalingTranslator <-> EncryptedConnection <-> SignalingSctpConnection
```

### The protocol it implements (ContentNegotiation.cpp, InstanceV2Impl.cpp)

- Media is a set of **one-way channels**. An offer lists the sender's **own outgoing channels, the
  complete set** (the receiver replaces what it had). An answer **echoes the offer's exchangeId** and
  lists the offerer's channels it accepted (offerer's ssrc). **Each side offers its own channels**:
  the callee answers the caller's first offer and then offers its own.
- A NegotiateChannels is an answer iff a local offer is pending and its exchangeId matches;
  everything else is an offer. Never decide by role. On glare the caller ignores the remote offer
  and the callee drops its own and answers.
- The data channel is **never negotiated**: SCTP on port 5000 over the same DTLS (or mtproto)
  transport, max message 262144, stream 0, caller opens with DCEP. 13.0.0 sends MediaState **only**
  on it and parses every data-channel text message as signaling.
- DTLS: caller client, callee server, for the whole call. 13.0.0 applies `setup` from every
  InitialSetup it receives, so a mid-call `actpass` from a callee would flip a 13.0.0 caller's role.
- 13.0.0 sends its InitialSetup **asynchronously, after** the answer and offer that need it.

### How CompatImpl maps it onto JSEP

The local PeerConnection negotiates against a remote description `SignalingTranslator` synthesises;
two 14.0.0 PeerConnections never see each other's SDP, only the wire.

- Outgoing audio and video are `kSendOnly` transceivers; remote channels get the `kRecvOnly`
  transceivers PeerConnection creates when it applies a remote offer. One video transceiver per call:
  camera off is `kInactive` with no track (the channel drops out of the next offer), camera on reuses it.
- Remote channel m-lines get mids of our choosing (`r<ssrc>`); the remote description's m-line order
  follows our local one, new remote channels appended. The caller's data channel section is accepted
  in every remote description (a callee's first remote offer adds one, mid `d`).
- **Invariants nothing enforces at compile time:**
  - **The MID / RID / repaired-RID header extensions are stripped everywhere.** Mids are local to each
    side and `RtpDemuxer` drops RTP carrying a MID it does not know (`rtp_demuxer.cc:297`).
  - **A section the peer only receives carries no ssrc.** `convertSignalingContentToContentInfo` adds
    `content.ssrc` unconditionally; two ssrc-0 streams in one BUNDLE group fail demuxing
    (`Failed to set up audio demuxing for mid='1'`).
  - **Rejected m-lines stay out of the BUNDLE group.**
  - **The remote `setup` is pinned by role** (remote `passive` for our caller, `active` for our
    callee) and our InitialSetup's `setup` is `actpass`/`passive` by role, never from our SDP.
  - **InitialSetup is applied on receipt**, not in order with NegotiateChannels: it is the peer's
    current ICE agent, and 13.0.0's arrives after its answer (a queued setup deadlocked 14→13).
  - **Remote NegotiateChannels are classified on receipt** (the pending exchangeId is cleared there,
    so the offer that trails an answer is not mistaken for glare) **and applied one at a time**,
    only while no SetLocal/RemoteDescription is in flight and no answer is owed.
  - Candidates are parsed with an empty mid and m-line 0: our mids are not the peer's.
  - A remote offer that fails SetRemoteDescription is not rolled back and needs no repair: the
    translator has already recorded its channels, but every remote offer resets `isOffered` and
    rebuilds the m-line list from the local description, and `makeAnswer` (which reads the
    remembered exchangeId) runs only after a successful SetRemoteDescription(offer) and
    SetLocalDescription(answer).
- Offers: either side, from `requestRenegotiation` (renegotiation-needed, capture change, ICE
  restart, an unassociated transceiver after a rollback), only from a quiet `kStable`. The callee
  waits for the caller's first offer; the caller waits (up to 10 s) for the callee's first offer, or
  under loss a crossing camera offer makes a 13.0.0 callee drop its audio offer for good.
- A failed remote answer rolls our offer back (a caller in have-local-offer would ignore every remote
  offer), a failed local answer rolls the remote offer back; automatic re-offers stop after 3
  consecutive failures.

### Known limitation (13.0.0's, not ours)

When both sides turn a camera on within one signaling round trip and the peer is a 13.0.0 callee,
the caller-wins rule makes that callee drop its offer, and 13.0.0 never re-offers (its
`_needNegotiation` was cleared when the offer was made): its camera stays unnegotiated until its next
camera change. 13 ↔ 13 does the same (5/8 at 30% signaling loss with both cameras toggled 2 s apart;
14 → 13 measured identically). 14 ↔ 14 is not affected: a CompatImpl callee re-offers after yielding.

### Testing

`tgcalls_cli` p2p prints `Remote media state` and, with `--video`/`--video-late`, `Video frames`
per side; "exit 0" alone never proved two-way media here. A healthy run: two audio send SSRCs (three
after a callee glare rollback), two signalled audio receive streams, no `Description failed`, one
`OPEN_ACK`, media state and frames both ways.

```bash
# every pairing, join-time and mid-call cameras (callee at 3 s, caller at 5 s)
tgcalls_cli --mode p2p --version 14.0.0 --version2 13.0.0 --duration 10 --video-late --log-file …
tgcalls_cli --mode p2p --version 13.0.0 --version2 14.0.0 --duration 10 --video --log-file …
# lossy signaling
tgcalls_cli --mode p2p --version 14.0.0 --duration 25 --drop-rate 0.3 --delay 50-200 --video-late
```

Measured 2026-10-11 (8 runs each): field-like delay (`--delay 100-300`) 8/8 in all six
pairing/video combinations; 30% loss with `--video`, audio-only, and 14 ↔ 14 `--video-late` 8/8;
`network_use_mtproto` on both ends works in all three pairings (data channel included, zero DTLS
handshakes). **Not exercised: the caller's ICE restart**, and with it every path that only a
credential change reaches: a second InitialSetup on the wire (each run above sends exactly one per
side), 13.0.0's `setRemoteParams` with a new ufrag mid-call, and PeerConnection detecting the
restart in a synthesised description. The CLI cannot fail ICE in p2p.

**A 14.0.0 build from before 2026-10-11 does not interoperate with one after it**, and the mixed
pairing is worse than old ↔ old. An old callee answers with its own counter (`exchangeId` 0), which
a new caller classifies as an offer and ignores as glare while its own offer is pending; the new
caller never leaves have-local-offer and **no media flows either way**. An old caller never applies a
new callee's offer (it needs an InitialSetup with every NegotiateChannels). Both are 14.0.0 on the
wire, so before serving 14.0.0 either bump the version string or wait until no pre-2026-10-11 build
can be selected for it.

Also ported 2026-10-11 from `InstanceV2ReferenceImpl`'s June–September fixes: ICE `failed` is not
terminal (caller-only `RestartIce`, 5 s throttle), Failed comes from a 20 s watchdog armed at start,
Reconnecting is debounced 2 s, a baseline network record is emitted at start, `onTransceiverRemoved`
finds the transceiver by receiver, and it reads `network_reflector_resolve_remote_candidate_ip` and
`network_use_mtproto`. Deliberately not ported: 11.0.0's `AddTrack` transceivers (`network_reference_use_addtrack`,
default on there since 2026-10-12; tgcalls `CLAUDE.md` "Do not implement" for CompatImpl) and `network_reference_allow_hostname_ice_servers` (`SocketAddress::IsComplete()`
is already true for a hostname with a port, so the gate it lifts never dropped a hostname).

13.2 sync (2026-11-07): under `network_signaling_nosctp` CompatImpl uses `ExternalSignalingConnection` instead of SCTP (framing unchanged), as `InstanceV2Impl`
does and as Android's 14.0.0 always does. Mute sets the audio sender's `encodings[0].active` (re-applied after every negotiation step) besides
disabling the track, so a muted call stops sending. Not ported: Telegram's 7.0.0/8.0.0/9.0.0 framing (the app registers `InstanceV2Impl` for those first).

Key files:
- `tgcalls/v2/InstanceV2CompatImpl.h/.cpp` — engine, negotiation queue, glare rules
- `tgcalls/v2/SignalingTranslator.h/.cpp` — the 13.0.0 protocol ↔ JSEP mapping
- `tgcalls/v2/Signaling.h/.cpp` — shared conversion functions (`convertContentInfoToSignalingContent`, `convertSignalingContentToContentInfo`)
