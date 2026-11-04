# Documentation index

`AGENTS.md` (imported by `CLAUDE.md`) holds what every session must know. Read the matching document before you
touch a subsystem. Documents describe how the code is now; a finished plan is deleted, its design record stays only if
it still explains a decision.

## Process

| Topic | Document |
|---|---|
| Development pipeline, shared-code rule, disk and worktree hygiene | [development-pipeline.md](development-pipeline.md) |
| Change records (`CHANGELOG.md`, `NANOGRAM-CHANGES.md`) in every repository and fork | [fork-records.md](fork-records.md) |
| Crash guardrails, lint, pre-push hook | [guardrails.md](guardrails.md) |
| Local development, what the fork changes, upstream sync, parity with the Mac | [local-development.md](local-development.md) |
| Cache cleanup policy | [cache-cleanup.md](cache-cleanup.md) |
| Shared paths with the Mac | [mac-core-paths.txt](mac-core-paths.txt) |
| Per-module build settings | [module-build-settings.md](module-build-settings.md) |
| Apple capabilities and signing | [release/apple-capabilities.md](release/apple-capabilities.md) |

## Build, test, simulator

| Topic | Document |
|---|---|
| Build, tests, host-only `bazel test` targets | [build-and-test.md](build-and-test.md) |
| Installing into the simulator, driving its UI, visual checks | [simulator.md](simulator.md), [visual-verification.md](visual-verification.md), [ui-testing.md](ui-testing.md) |
| CI in tart VMs | [ci-tart-vms.md](ci-tart-vms.md) |
| Upgrading FFmpeg and SQLCipher | [vendored-upgrades.md](vendored-upgrades.md) |
| Code style, project structure | [code-style-and-structure.md](code-style-and-structure.md) |
| Swift 6.4 compiler pitfalls | [compiler-pitfalls-swift-6-4.md](compiler-pitfalls-swift-6-4.md) |
| Framework export lists | [framework-export-lists.md](framework-export-lists.md) |

## Performance rules

[performance/main-thread-and-composer.md](performance/main-thread-and-composer.md),
[performance/per-module-optimization.md](performance/per-module-optimization.md),
[performance/timers-and-wakeups.md](performance/timers-and-wakeups.md).

## Subsystems

| Subsystem | Document |
|---|---|
| Composer (RichTextEditor, ChatInputContent) | [richtext-composer.md](richtext-composer.md), [subsystems/composer-harness.md](subsystems/composer-harness.md), `Tests/ComposerHarness/CLAUDE.md` |
| InputDec engine and kernel | [subsystems/inputdec-engine.md](subsystems/inputdec-engine.md) |
| InstantPage V2 and rich-text messages | [instantpage-richtext.md](instantpage-richtext.md) |
| Windows and touches (iOS 26/27), iPhone Duo layout | [ios27-windows-and-touches.md](ios27-windows-and-touches.md), [iphone-duo-layout.md](iphone-duo-layout.md) |
| Chat history list and the CoreList backend | [subsystems/chat-history-list.md](subsystems/chat-history-list.md), [chat/corelist-chat-history-backend.md](chat/corelist-chat-history-backend.md) |
| Media I/O, decode, animation caches, voice recorder | [subsystems/media-io.md](subsystems/media-io.md), [subsystems/media-decode-and-voice.md](subsystems/media-decode-and-voice.md) |
| TelegramApi (generated API layer) | [subsystems/telegram-api.md](subsystems/telegram-api.md) |
| Rust MTProto engine | [subsystems/mtproto-rust-engine.md](subsystems/mtproto-rust-engine.md) |
| Network telemetry, WEB proxy carrier | [subsystems/network-telemetry-and-web-proxy.md](subsystems/network-telemetry-and-web-proxy.md) |
| JPEG library | [subsystems/mozjpeg.md](subsystems/mozjpeg.md) |
| Background diagnostic and the lock task | [subsystems/background-diagnostic.md](subsystems/background-diagnostic.md) |
| Postbox: history views, shared-media removal, Engine refactor | [subsystems/postbox-history-and-shared-media.md](subsystems/postbox-history-and-shared-media.md), [subsystems/postbox-engine-refactor.md](subsystems/postbox-engine-refactor.md), [superpowers/postbox-refactor-log.md](superpowers/postbox-refactor-log.md) |
| Channel posts, News feed | [subsystems/channel-post-and-news-feed.md](subsystems/channel-post-and-news-feed.md) |
| Non-contact chats (suspicious peer) | [subsystems/suspicious-peer.md](subsystems/suspicious-peer.md) |
| Calls (tgcalls, WebRTC) | [subsystems/tgcalls.md](subsystems/tgcalls.md), [subsystems/tgcalls/](subsystems/tgcalls/) (the former `submodules/TgVoipWebrtc/CLAUDE.md`) |
| Watch app | [subsystems/watch-app.md](subsystems/watch-app.md) |
| Passcode | [passcode.md](passcode.md) |
| Context menu morph | [context-menu-liquid-morph.md](context-menu-liquid-morph.md) |

## Research and records

[research/](research/) (GPU sticker rendering, unlinked vendored code, WebRTC CVEs), [superpowers/specs/](superpowers/specs/)
(design records and the runtime-efficiency and integration spec lists R1-R23 etc.), [superpowers/duo-screen-audit-2026-10.md](superpowers/duo-screen-audit-2026-10.md).

## Where the old CLAUDE.md sections went

Until 2026-11-05 `CLAUDE.md` was a 1821-line manual. Other documents may still say "see CLAUDE.md, section X"; look it up here.

| Old CLAUDE.md section | Now |
|---|---|
| Build (command, tests, platform hardening) | build-and-test.md |
| Updating the simulator, Driving the simulator UI, Visual features | simulator.md |
| CI builds in tart VMs | ci-tart-vms.md |
| Upgrading FFmpeg / SQLCipher | vendored-upgrades.md |
| Code Style Guidelines, Project Structure | code-style-and-structure.md |
| RichTextEditor and ChatInputContent | richtext-composer.md (end), subsystems/composer-harness.md |
| Embedded watch app | subsystems/watch-app.md |
| The vendored InputDec engine and kernel | subsystems/inputdec-engine.md |
| Main-thread and composer hot paths | performance/main-thread-and-composer.md |
| iOS 26/27 windows and touch delivery | ios27-windows-and-touches.md (end) |
| iPhone Duo layout | iphone-duo-layout.md (end) |
| Swift 6.4 (two sections) | compiler-pitfalls-swift-6-4.md |
| Per-module -O and pixel loops | performance/per-module-optimization.md |
| Timers and wake-ups | performance/timers-and-wakeups.md |
| Media I/O invariants | subsystems/media-io.md |
| Media decode, animation caches, voice recorder | subsystems/media-decode-and-voice.md |
| Framework export lists | framework-export-lists.md |
| TelegramApi | subsystems/telegram-api.md |
| Neighbor descriptors, View frame ownership, ChatHistoryListNode composition, Message send transition | subsystems/chat-history-list.md |
| InstantPage V2 | instantpage-richtext.md (end) |
| Rust MTProto engine on iOS | subsystems/mtproto-rust-engine.md |
| Network telemetry, WEB proxy carrier | subsystems/network-telemetry-and-web-proxy.md |
| JPEG library | subsystems/mozjpeg.md |
| Background diagnostic | subsystems/background-diagnostic.md |
| Postbox history views, shared-media removal | subsystems/postbox-history-and-shared-media.md |
| Opening a channel at a post, News feed, Opening a post | subsystems/channel-post-and-news-feed.md |
| Non-contact's chat (suspicious peer) | subsystems/suspicious-peer.md |
| Postbox to TelegramEngine refactor | subsystems/postbox-engine-refactor.md |
| Shared tgcalls code, tgcalls Testbench | subsystems/tgcalls.md |
| `submodules/TgVoipWebrtc/CLAUDE.md` (761 lines) | subsystems/tgcalls/*.md, 7 files |
