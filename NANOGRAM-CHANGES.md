# How Nanogram for iOS differs from Telegram-iOS

Upstream: https://github.com/TelegramMessenger/Telegram-iOS, imported as one snapshot commit per `release-*` tag on the
branch `upstream` (now `release-13.1.2`, 0650eac5). Ours: `main` (443 commits ahead at 2026-11-05, 17.8k files differ,
mostly the history-free import layout and generated files). Format: [docs/fork-records.md](docs/fork-records.md).
History of builds: [CHANGELOG.md](CHANGELOG.md). Last checked against `git diff upstream..main --stat`: 2026-11-05.

This file is a first version assembled from docs/local-development.md, CHANGELOG.md and the former CLAUDE.md. Entries
marked (check) were not re-verified against the code; correct them on the next change in that area.

### Build speed and disk use
- What: Bazel 9.3 with APFS copy-on-write disk cache, `--watchfs`, extensions skipped by default, host tools at
  `-O0`, parallel `make` in native library scripts, shallow submodules, history-free repository, shared bounded
  caches, cache cleanup after build commands.
- Why: local builds on one 32 GB laptop with a full disk.
- Where: `.bazelrc`, `versions.json`, `MODULE.bazel`, `tools/dev/tg`, `tools/dev/cachegc/`, `build-system/Make/`.
- Upstream: no (their CI uses other trade-offs).
- Sync: expect conflicts in `MODULE.bazel(.lock)`, `versions.json`, `.gitmodules`; see docs/local-development.md "Keeping up with upstream".

### Strictness and guardrails
- What: new modules use `strict_swift_library` (Swift 6 mode, warnings as errors); SwiftLint on changed lines; pre-push
  hook; crash guardrails (no runtime-trap removal flags); parity gate with the Mac app.
- Where: `build-system/bazel-utils/swift_strict.bzl`, `tools/dev/lint/`, `tools/dev/parity/`, `docs/guardrails.md`.
- Upstream: partly (strict modules could be offered; the tooling is ours).
- Sync: none; tests in `tools/dev/lint/tests`, `tools/dev/tests`.

### Security hardening
- What: minimal entitlements per extension, optional Enhanced Security entitlements (off), hardened C-family flags,
  Lockdown Mode policy (`submodules/HardenedMedia`), code-block highlighter recursion bound (`third-party/libprisma`),
  external-link login-part check (`UrlWhitelist`), WebRTC/tg_owt CVE fixes.
- Why: owner's security review (2026-11-04); remote DoS and key-handling findings.
- Where: `Telegram/entitlements.bzl`, `submodules/BuildConfig`, `submodules/HardenedMedia`, `third-party/libprisma`, `submodules/UrlWhitelist`, `.bazelrc`, `third-party/webrtc` (fork).
- Upstream: partly (libprisma and WebRTC fixes yes).
- Sync: libprisma is `desktop-app/libprisma` 94640c6 plus `TokenizeStats`/`TokenizeLimits`; re-add those hooks on refresh.

### Shared core with the Mac app
- What: this repository is the Telegram core of Nanogram for macOS; Mac-only behaviour sits behind `#if os(macOS)`;
  `native-libs.json`, module settings table, parity gate, shared cache policy.
- Where: `docs/mac-core-paths.txt`, `tools/dev/parity/`, `native-libs.json`, `tools/dev/cachegc/`.
- Upstream: no.
- Sync: a change to a shared path needs the Mac `tg core-bump`; the pre-push hook reminds.

### Calls (tgcalls, WebRTC, rlottie forks)
- What: tgcalls runs from `klaipher/tgcalls` `nanogram-shared` (iOS and Mac in one implementation), WebRTC from
  `klaipher/webrtc` `nanogram-security-fixes`, runtime switches (`CallsRuntimeSwitches`), CallKit/Siri call-back fixes,
  Phone Recents switch.
- Where: `submodules/TgVoipWebrtc/`, `third-party/webrtc/`, `.gitmodules`. Records of the forks live in the forks.
- Upstream: partly. Sync: `tools/dev/tgcalls-port`, `submodules/TgVoipWebrtc/CLAUDE.md`.

### Rust MTProto engine, network
- What: the MTProto transport runs on the Rust `mtproto-engine`; network telemetry, WEB proxy carrier, MultipartUpload
  and FetchV2 tuning, TCP keepalive. (check)
- Where: `third-party/mtproto-engine`, `submodules/MTProtoRustEngine` (check), docs/subsystems/mtproto-rust-engine.md, docs/subsystems/network-telemetry-and-web-proxy.md.

### Composer and rich text
- What: native rich-text editor (`RichTextEditor`) and the InputDec engine as the composer backend, InstantPage V2,
  message widgets.
- Where: `submodules/TelegramUI/Components/RichTextEditor`, docs/richtext-composer.md, docs/subsystems/inputdec-engine.md, docs/instantpage-richtext.md.
- Upstream: no.

### Storage, media, performance
- What: MediaBox / SQLite write accounting, HLS single write, GPU sticker paths, animation cache decoding, per-module
  `-O`, timer and wake-up reductions.
  Cache walkers (time-based cleanup scan, automatic cache eviction) run at most once a day, not in the first minute
  after launch, with the last run kept in the StorageBox metadata; cache touches `stat` before `utime`;
  `debug_measureTimeToFirstEvent` is DEBUG-only; the media player timer has a tolerance and stops when paused;
  hardware VP9 sticker counters and session release when hidden or once the frame cache is complete.
- Where: docs/subsystems/media-io.md, docs/subsystems/media-decode-and-voice.md, docs/performance/.

- Chat photos decode complete JPEGs at the drawn size (`ImageDecodeSizing`, used by `PhotoResources`), the photo picker issues thumbnail requests off the main thread, and `ChatHistoryListNode.processDisplayedItemRangeChanged` caches its whole-history scan per history view (all three differ from upstream; round 3, iOS UI performance).

### Chat features
- What: News feed, opening a channel at a post, suspicious-peer chat gate, Postbox to TelegramEngine refactor, CoreList chat history backend. (check)
- Where: docs/subsystems/channel-post-and-news-feed.md, docs/subsystems/suspicious-peer.md, docs/chat/.
- Context-menu reaction with the keyboard up lands through the chat's standalone animation (menu in the keyboard window cannot show the flight). Where: `ContextReactionLandingRoute.swift`, `ChatContextReactionStandaloneLanding.swift`. Upstream: no.

### Platforms
- What: iPad (resizable chat list, window controls, Split View cameras), iPhone Duo reserved corners, iOS 26/27 window and touch handling, standalone Apple Watch client.
- Where: docs/iphone-duo-layout.md, docs/ios27-windows-and-touches.md, `Telegram/WatchApp`.

### Branding and identity
- What: Nanogram name, icons (Sphere default), bundle names, Siri phrases, language packs; a lint keeps Telegram's name and logo out. Own bundle identifiers and team.
- Where: `tools/dev/lint/branding.py`, `Telegram/Telegram-iOS/Nanogram.icon`.
- Upstream: no.
