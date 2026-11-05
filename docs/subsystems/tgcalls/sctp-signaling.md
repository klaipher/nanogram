# tgcalls: SCTP signaling, writable gate, timer tuning

## SCTP Signaling

### Writable Gate (role-based handshake ordering)

tgcalls uses a custom SCTP association (via dc-sctp) over the signaling channel for reliable message delivery. `SignalingSctpConnection` wraps `DcSctpTransport` with a `SignalingPacketTransport` shim.

The SCTP handshake is ordered using DcSctpTransport's writable gate (`MaybeConnectSocket()`), mirroring how WebRTC PeerConnection uses DTLS writable state to control SCTP connection timing:

- **Caller** (`isOutgoing=true`): `SignalingPacketTransport` starts writable → `Connect()` fires immediately → sends INIT
- **Callee** (`isOutgoing=false`): starts not-writable → `Connect()` deferred → on first `receiveExternal()`, `setWritable(true)` fires `SignalWritableState` → `MaybeConnectSocket()` → `Connect()`

The callee's `Connect()` and processing of the caller's INIT happen synchronously within the same `BlockingCall` on the network thread (RFC 4960 §5.2.1 simultaneous-open).

Key files:
- `SignalingSctpConnection.cpp` — `SignalingPacketTransport` writable state, `setWritable()`, constructor takes `isInitiator`
- `InstanceV2Impl.cpp` / `InstanceV2ReferenceImpl.cpp` — pass `_encryptionKey.isOutgoing` as `isInitiator`
- `third-party/webrtc/webrtc/media/sctp/dcsctp_transport.cc:662-667` — `MaybeConnectSocket()` gate (unmodified)

### Timer Tuning (CustomDcSctpSocket)

WebRTC's stock `DcSctpSocket` has a bug: `max_timer_backoff_duration` is wired to the T3-rtx (data retransmission) timer but **not** to the t1_init and t1_cookie (handshake) timers. The handshake timers use unlimited exponential backoff (1000, 2000, 4000, 8000ms...), causing the SCTP handshake to stall for 20+ seconds under packet loss with simultaneous-open (both sides call `Connect()`).

Fix: `CustomDcSctpSocket` (in `tgcalls/v2/`) is a copy of `DcSctpSocket` with the 6-line fix that passes `max_timer_backoff_duration` to the t1_init and t1_cookie timer constructors. A `CustomDcSctpSocketFactory` in `SignalingSctpConnection.cpp` creates it instead of the stock socket, with configurable timer overrides. WebRTC source is **untouched**.

Default signaling SCTP timer values (set in `SignalingSctpConnection::Options`):

| Setting | WebRTC Default | Signaling Override |
|---|---|---|
| `t1_init_timeout` | 1000ms | 400ms |
| `t1_cookie_timeout` | 1000ms | 400ms |
| `max_timer_backoff_duration` | 3000ms | 750ms |
| `max_init_retransmits` | 8 | unlimited (from `DcSctpTransport::Start`) |

Retry pattern: 400ms, 750ms, 750ms, 750ms... (~18 attempts in 15s). At 30% loss, 100% success rate over 5000 runs.

These values are configurable via JSON custom parameters (passed to `InstanceV2Impl` via `config.customParameters`):
- `network_sctp_t1_init_ms` — T1-init timeout (0 = use default 400ms)
- `network_sctp_t1_cookie_ms` — T1-cookie timeout (0 = use default 400ms)
- `network_sctp_max_backoff_ms` — max timer backoff cap (0 = use default 750ms)

Key files:
- `tgcalls/v2/CustomDcSctpSocket.h/.cpp` — patched `DcSctpSocket` copy
- `tgcalls/v2/SignalingSctpConnection.cpp` — `CustomDcSctpSocketFactory`, timer option plumbing
- `tgcalls/v2/InstanceV2Impl.cpp` — reads JSON params, passes `Options` to `SignalingSctpConnection`
