# Vendored code that is not linked into the app

Compiled 2026-11-02 for Round J of the deep audit. Documentation only: nothing is deleted.

**Method.** The audit compared `bazel query 'deps(//Telegram:Telegram)'` with every rule under
`//submodules` and `//third-party` (84 rules not reached, kept in the audit's
`unreached-targets.txt`). For each entry below the references were checked again on this branch
with a search of every `BUILD`, `.bzl` and Swift file. Not being linked means no binary size,
launch or runtime cost: the cost is checkout size, review and update time, and false positives
in dependency and CVE scans.

## Not linked and not used by anything

| Code | Size | Why it is not linked | Recommendation |
|---|---|---|---|
| `third-party/libjxl` (`:jxl`, `:jxl_lib`, `:libjxl_build`, `:libjxl_sources`) | 28 MB, 1,579 files, 510 C/C++ sources | The only reference is a commented-out dep in `submodules/MozjpegBinding/BUILD` (`#"//third-party/libjxl:jxl"`); `USE_JPEGXL` is not defined anywhere. It was still updated to 0.12.0 (d234a8d2). | **Remove.** It is the largest item and is updated for nothing. If JPEG XL is ever needed, ImageIO decodes it natively on iOS 17 and later. |
| `third-party/XMLCoder` | 52 files | No `BUILD` file or Swift import refers to it. | **Remove.** |
| `third-party/Swift2D` | 7 files | No references. | **Remove.** |
| `submodules/TelegramUI/Components/SpaceWarpView/STCMeshView` | 2 ObjC sources | `SpaceWarpView` depends on `MeshTransform` instead; nothing depends on `STCMeshView`. | **Remove.** |
| `submodules/TelegramUI/Components/ChatScheduleTimeScreen` | 1 Swift source | Superseded: the screen lives in `Components/ChatScheduleTimeController` (its own `ChatScheduleTimeScreen.swift`), which is what the app uses. | **Remove**, after checking that nothing in the old copy is newer than the one in `ChatScheduleTimeController`. |
| `submodules/TelegramUI/Components/Wallet/WalletCollectibleItemComponent` | 1 Swift source | No dependents. | **Remove**, or wire it in if the wallet's collectibles screen was meant to use it (ask the wallet owner). |

## Not linked on purpose (targets inside linked packages)

| Target | What it is | Recommendation |
|---|---|---|
| `//third-party/boringssl:bssl` | BoringSSL's command-line tool (`cc_binary`). | Keep: part of the upstream tree, useful for debugging TLS. |
| `//submodules/TgVoipWebrtc:tgcalls_core`, `:variant_core_wasm`, `:is_macos`, `tgcalls/tools/cli`, `tgcalls/tools/go_sfu` | tgcalls for host tools, the WebAssembly call core, a config setting, a CLI and a Go SFU for testing. | Keep: build and test tooling. |
| `third-party/mtproto-engine/bench/*/Vendor/{MtProtoKit,OpenSSLEncryptionProvider}` | Vendored copies for the engine's benchmark clients (inside the `mtproto-engine` submodule). | Keep: benchmark-only, owned by the engine repository. |
| `//submodules/TelegramUI:composer_state_writer_sources`, `//submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode:composer_state_writer_sources` | Filegroups that `ChatRichTextEditorComposerTests` reads at run time (`data`). | Keep: test data. |
| `//submodules/LegacyComponents/Tests:*`, `//submodules/MtProtoKit:MtProtoKitPrivateHeaders` and the 50-odd `*TestsLib` targets | Test hosts and test libraries. | Keep: tests. |

## Not an issue

`submodules/SSignalKit` and `submodules/Utils` appear in the audit's package list because their
top-level directory has no target of its own; their subpackages (`SwiftSignalKit`, `RangeSet`,
`DeviceModel`, …) are linked.

## If the removals are done

One commit per entry, each removing the directory, any `BUILD` reference (the commented-out
libjxl dep), and its mentions in `CLAUDE.md`/docs, followed by a full `tools/dev/tg build`.
Removing libjxl also removes it from the dependency-update routine that bumped it in d234a8d2.
