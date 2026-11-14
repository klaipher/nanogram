# Shared tgcalls code and the testbench

## Shared tgcalls code: iOS and Mac

The iOS, Mac and Android apps pin the same commit of `klaipher/tgcalls` branch `nanogram-shared` (one branch, one engine; plan W4). Most of the engine is shared (1:1 and group calls, livestreams, `tgcalls/platform/darwin` capture/encode/decode), so **a fix in shared tgcalls code is one fork commit and the three pins move to it**. The iOS Objective-C++ bridge (module `TgVoipWebrtc`) lives in the fork under `ios/` (`Sources`, `PublicHeaders`, `tests`); `submodules/TgVoipWebrtc/BUILD` points into it. There is no per-platform port step.

- Keep platform code inside `TARGET_OS_IOS` / `WEBRTC_IOS` (or `WEBRTC_MAC`) guards; new virtuals on `PlatformInterface`, `VideoCaptureInterface`, `VideoCapturerInterface` get a default body so the other platform still compiles.
- Commit shared fixes as their own tgcalls commits (not mixed with platform-only work) on `nanogram-shared`, then move the iOS, Mac and Android pins to that commit the same day (`tools/dev/native/check_shared.py` reports a pin that differs from the manifest). `tools/dev/tgcalls-port` is gone.
- Still open (2026-11-04): iOS and Mac each built their own livestream hardware decode (`LivestreamDecodePolicy.h` + `CallsRuntimeSwitches` vs `TGLivestreamDecode.h` + `RuntimeOptions`), audio policy (`AudioCallPolicy.h` vs `CallAudioPolicy.h`) and call-power policy (`CallPowerPolicy.h`/`StreamRenderPolicy.h` vs `CallSystemPolicy.h`). A trial merge of the Mac branch into `telegram-ios-dev` conflicts in 10 files (19 hunks: `VideoStreamingPart.cpp`, `DarwinFFMpeg.mm`, `TGRTCVideoEncoderH264.mm`, `StreamingMediaContext.cpp`, `InstanceV2Impl.cpp`, `GroupInstanceCustomImpl.cpp`, `VideoCaptureInterfaceImpl.cpp`, `LogSinkImpl.*`, `tests/log_sink`); resolving them is a design choice per feature (one implementation, one switch name), not a mechanical merge, and needs a Mac build to check. Until that is done, port each shared fix with the script above.

## tgcalls Testbench

This repo includes a tgcalls testbench (CLI tool, Go/Pion SFU, Docker build) layered on top of the iOS source. All testbench code, build instructions, and architecture docs live inside the tgcalls submodule:

- `submodules/TgVoipWebrtc/tgcalls/CLAUDE.md` — top-level testbench overview, build/run commands
- `submodules/TgVoipWebrtc/tgcalls/tools/cli/CLAUDE.md` — CLI test tool architecture
- `submodules/TgVoipWebrtc/tgcalls/tools/go_sfu/CLAUDE.md` — Go SFU internals
- `submodules/TgVoipWebrtc/CLAUDE.md` — tgcalls library internals + macOS/Linux build patches
- `submodules/TgVoipWebrtc/tgcalls/tgcalls/v2wasm/CLAUDE.md` — pump-boundary call core: `InstanceV2ReferenceImpl`'s control logic behind a C ABI (since Phase 2.5 a PeerConnection-projection contract: SDP munge point, transceiver/parameter/ICE-restart commands, rich stats, and since Phase 2.6 core-owned signaling framing, N named data channels, and audio/ICE config knobs), runnable natively or as a WASM module in the vendored WAMR interpreter. **Ships as call versions `18.0.0` (native core) and `19.0.0` (the same source as wasm embedded in the binary)** so a server-side A/B can measure the substrate alone; the client advertises both and the server reconciles. `customParameters.wasm_core_path` and the filesystem module loader are compiled out of the app (`TGCALLS_ALLOW_EXTERNAL_WASM_CORE`, CLI target only) — never add that define to the `TgVoipWebrtc` objc_library. A second module `variant-core-abi1.wasm` demonstrates behavior changes (fmtp munge, adaptive bitrate cap, periodic ICE restart) shipped as wasm only, CLI-loaded. Design/validation records in `docs/superpowers/specs/2026-07-*-tgcalls-wasm-*`

Build the test binary from this directory with:

`./build-input/bazel-9.3.1-darwin-arm64 build //submodules/TgVoipWebrtc/tgcalls/tools/cli:tgcalls_cli`
