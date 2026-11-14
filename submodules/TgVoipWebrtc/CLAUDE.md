# tgcalls library (TgVoipWebrtc)

The tgcalls VoIP library source, a submodule fork (`klaipher/tgcalls`, branch `nanogram-shared`, shared with the Mac and Android apps).
The repository rules are in the root `AGENTS.md`; the fork's own build, CLI and mass-test manual is `tgcalls/CLAUDE.md`
inside the submodule. The iOS Objective-C++ bridge (`Sources`, `PublicHeaders`, `tests`) lives in the fork's `ios/` directory; this package's BUILD reads it from there. One fork branch (`nanogram-shared`) serves iOS, Mac and Android: a shared fix is one fork commit and the three pins move to it (no port step).
Every change here also gets an entry in the fork's own `CHANGELOG.md` / `NANOGRAM-CHANGES.md` (docs/fork-records.md).

Read the matching document before touching an area:

| Area | Document |
|---|---|
| macOS and Linux build, vendored WebRTC seams | docs/subsystems/tgcalls/build-macos-linux.md |
| SCTP signaling, writable gate, timers | docs/subsystems/tgcalls/sctp-signaling.md |
| InstanceV2CompatImpl (protocol 14.0.0) | docs/subsystems/tgcalls/instancev2-compat.md |
| GroupInstanceCustomImpl | docs/subsystems/tgcalls/group-custom-impl.md |
| GroupInstanceReferenceImpl (PeerConnection group calls) | docs/subsystems/tgcalls/group-reference-impl.md |
| Video pitfalls, known issues | docs/subsystems/tgcalls/video-pitfalls-and-known-issues.md |
| Call video/audio switches, review fixes | docs/subsystems/tgcalls/call-switches-and-review-fixes.md |
| Host tests and testbench | docs/subsystems/tgcalls.md |
