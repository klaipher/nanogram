# tgcalls: GroupInstanceCustomImpl

## GroupInstanceCustomImpl (Group Calls)

The group call implementation in `tgcalls/group/GroupInstanceCustomImpl.cpp` (~4700 lines). Uses a client-server model with an SFU, unlike 1:1 calls which are peer-to-peer.

### Protocol Stack
- **Join signaling**: JSON over application layer (`emitJoinPayload` → app sends to SFU → `setJoinResponsePayload`)
- **Transport**: ICE + DTLS-SRTP over UDP (standard WebRTC transport, NOT PeerConnection)
- **Media**: RTP/RTCP with Opus audio (48kHz, 2ch, 32kbps), optional VP8/H264/VP9 video
- **Control**: SCTP data channel over DTLS for Colibri protocol (video constraints, debug messages)

### Join Flow
1. Client calls `emitJoinPayload()` → generates JSON with audio SSRC, ICE ufrag/pwd, DTLS fingerprint
2. Application sends JSON to SFU server
3. Server responds with its ICE candidates, DTLS fingerprint, video codec info
4. Client calls `setJoinResponsePayload(json)` → ICE/DTLS negotiation begins
5. On connection: `networkStateUpdated` callback fires

### Participant Discovery
- Unknown SSRC arrives in RTP → `receiveUnknownSsrcPacket()` → `maybeRequestUnknownSsrc(ssrc)`
- App's `requestMediaChannelDescriptions` callback queries server for SSRC→participant mapping
- `addIncomingAudioChannel(ssrc, userId)` creates decoder channel

### Colibri Data Channel Messages
```json
// SFU → Client
{"colibriClass": "SenderVideoConstraints", "videoConstraints": {"idealHeight": 360}}

// Client → SFU
{"colibriClass": "ReceiverVideoConstraints", "defaultConstraints": {"maxHeight": 0},
 "onStageEndpoints": ["endpoint1"],
 "constraints": {"endpoint1": {"minHeight": 180, "maxHeight": 720}}}
```

Heights are on the layer scale 180/360/720 (thumbnail/medium/full): `minHeight` from the channel's
`minQuality`, `maxHeight` from its `maxQuality`, and every `maxQuality == Full` endpoint is listed in
`onStageEndpoints` (`maybeUpdateRemoteVideoConstraints`). Both engines must send exactly this shape;
see "Receiver video constraints" under ReferenceImpl for what happened when one did not.

### Key Files
- `tgcalls/group/GroupInstanceCustomImpl.h/.cpp` — main implementation
- `tgcalls/group/GroupNetworkManager.h/.cpp` — ICE/DTLS/SRTP transport
- `tgcalls/group/GroupJoinPayloadInternal.h/.cpp` — join JSON serialization
