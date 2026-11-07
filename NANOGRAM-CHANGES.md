# How Nanogram for iOS differs from Telegram-iOS

Upstream: https://github.com/TelegramMessenger/Telegram-iOS, imported as one snapshot commit per `release-*` tag on the
branch `upstream` (now `release-13.2`, 5083532f). Ours: `main` (443 commits ahead at 2026-11-05, 17.8k files differ,
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
- What: minimal entitlements per extension, optional Enhanced Security entitlements (on for TestFlight builds since the three App IDs have the capability; verified before each upload), hardened C-family flags,
  Lockdown Mode policy (`submodules/HardenedMedia`), code-block highlighter recursion bound (`third-party/libprisma`),
  external-link login-part check (`UrlWhitelist`), WebRTC/tg_owt CVE fixes.
- Why: owner's security review (2026-11-04); remote DoS and key-handling findings.
- Where: `Telegram/entitlements.bzl`, `submodules/BuildConfig`, `submodules/HardenedMedia`, `third-party/libprisma`, `submodules/UrlWhitelist`, `.bazelrc`, `third-party/webrtc` (fork).
- Upstream: partly (libprisma and WebRTC fixes yes).
- Sync: libprisma is `desktop-app/libprisma` 94640c6 plus `TokenizeStats`/`TokenizeLimits`; re-add those hooks on refresh.

### Message widgets (13.2) gates
- What: upstream's message widgets (a bot's HTML/CSS/JS run in the app process) are on by default there, switched off only by the server. Here they also stop when Lockdown Mode is on (`HardenedMediaPolicy.allowsMessageWidgets`) and by a local Debug Settings switch (default on); the widget wallet is off behind a second Debug switch (default off) until tested on a device with a funded wallet; a crash sentinel (`MessageWidgetCrashSentinel`) makes a source that was running when the app last crashed start stopped (the static "Widget stopped" badge) for 7 days.
- Where: `chatMessageWidgetRenderingEnabled` (`ChatMessageWidgetBubbleContentNode`), `MessageWidgetLocalSettings`, `MessageWidgetWalletAvailability.isReady`, `MessageWidgetRegistry` (sentinel), `DebugController` rows, `HardenedMedia`.
- Why: widgets run sender code in-process, the hardened libc++ build may trap where upstream's build is silent, and the wallet path has never run end to end upstream (review up132 I3, W1-W3).
- Upstream: no.
- Sync: expect small conflicts in `MessageWidgetRegistry.swift`, `MessageWidgetWalletAvailability.swift` and the bubble node's `chatMessageWidgetRenderingEnabled`.

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
  hardware VP9 sticker counters and session release when hidden or once the frame cache is complete;
  the MediaBox open-handle table evicts the least recently used handle (upstream: the oldest opened) and Postbox logs
  which transaction call sites append the most WAL frames; the direct-fetch lookahead thread is woken only when its
  buffer needs a refill (upstream: on every position update); Postbox decodes message text from memory without a
  `Data` copy; the universal software video source reads complete files through one handle.
- Where: docs/subsystems/media-io.md, docs/subsystems/media-decode-and-voice.md, docs/performance/.

- Chat photos decode complete JPEGs at the drawn size (`ImageDecodeSizing`, used by `PhotoResources`), the photo picker issues thumbnail requests off the main thread, and `ChatHistoryListNode.processDisplayedItemRangeChanged` caches its whole-history scan per history view (all three differ from upstream; round 3, iOS UI performance).

- The new photo picker grid (MediaGrid, Telegram 13.2) runs with the iCloud thumbnail lane off, a background thumbnail filler that runs only while a library picker is open (foreground, not in Low Power Mode or at serious thermal state, 4 requests at a time), a 60,000 thumbnail cap on the store, requests issued off the main thread, a single image delivery for cells under 512 px, and a store that Storage Usage's "Clear cache" empties; upstream's grid runs unpaced with the iCloud lane on (`MediaGridPhotoLibraryServices.applyAppPacing`, `ThumbnailFillPacing`).

### Chat features
- What: News feed, opening a channel at a post, suspicious-peer chat gate, Postbox to TelegramEngine refactor, CoreList chat history backend. (check)
- Where: docs/subsystems/channel-post-and-news-feed.md, docs/subsystems/suspicious-peer.md, docs/chat/.
- Context-menu reaction with the keyboard up lands through the chat's standalone animation (menu in the keyboard window cannot show the flight). Where: `ContextReactionLandingRoute.swift`, `ChatContextReactionStandaloneLanding.swift`. Upstream: no.

### Platforms
- What: iPad (resizable chat list, window controls, Split View cameras), iPhone Duo reserved corners, iOS 26/27 window and touch handling, standalone Apple Watch client.
- Where: docs/iphone-duo-layout.md, docs/ios27-windows-and-touches.md, `Telegram/WatchApp`.
- iOS 27 glass backdrop overrides: `registerEffectViewOverrides` (`UIViewController+Navigation.m`) skips the `UISDFBackdropView` lookup on iOS 27 (upstream 13.1.2 looks it up by the iOS 26 name, misses, and pays a failed mangled-name scan of about 45 ms in +load). Superseded by the native-glass entry in the 13.2 merge list below: the lookup is skipped on iOS 27 unless the fixed-look switch is on.

### Branding and identity
- What: Nanogram name, icons (Sphere default), bundle names, Siri phrases, language packs; a lint keeps Telegram's name and logo out. Own bundle identifiers and team.
- Where: `tools/dev/lint/branding.py`, `Telegram/Telegram-iOS/Nanogram.icon`.
- Upstream: no.

### Call switch defaults (iOS)
- What: livestream hardware decoding, native camera frames, system noise suppression, the thermal video ladder and group
  noise = RNNoise only are on by default and stay switchable in Debug Settings; each has a new storage key so earlier saved
  values do not count. Advanced ducking, the reference engine, VoIP TCP and on-device translation stay off.
- Why: owner decision, 2026-11-06 (measured wins, local only, nothing on the wire).
- Where: `submodules/TelegramUIPreferences/Sources/ExperimentalUISettings.swift`, `docs/subsystems/tgcalls/call-switches-and-review-fixes.md`.
- Upstream: no (the switches are ours).
- Sync: none.

### Call controls (iOS)
- What: route requests are skipped only when the session reports that route; CallKit mute uses `callUUID`, is reported back
  from the app (its own echo ignored), reaches the conference after a 1:1 upgrade, and the loudspeaker is put back after a
  reactivation while the route is the phone's own; camera facing follows the capturer; the 1:1 camera preview releases the
  camera on any dismissal that is not a share; short-log lines for route requests.
- Why: iPhone 14 speaker report and the controls audit (2026-11-06).
- Where: `submodules/TelegramCallsUI/Sources/{AudioOutputRequestPolicy,CallKitActionTarget,CallKitMuteSync,CameraFacingTracker,CallKitIntegration,PresentationCall,PresentationCallManager,PresentationGroupCall,SharedCallAudioContext}.swift`, `submodules/TelegramAudio/Sources/{ManagedAudioSession,AudioRouteClassification}.swift`.
- Upstream: all of these are upstream code paths (`setCurrentAudioOutput`, `action.uuid`, `setCallMutedImpl`, `useFrontCamera`); expect conflicts there on import.
- Sync: re-check the three guards when `PresentationCall.swift` / `SharedCallAudioContext.swift` change upstream.

### Liquid Glass usage (iOS)
- What: the floating chat history buttons share one `GlassBackgroundContainerView` and their badge is a tinted fill, not
  glass on glass; the history button keeps `isInteractive` after a theme update; `GlassBackgroundContainerView.update`
  applies size and style only when changed; the custom parts of glass (legacy fill and rim before iOS 26, custom blur
  radius in the context menu and QR Studio) follow Reduce Transparency and Increase Contrast live (`GlassEnvironment`);
  Debug Settings ▸ Glass groups switches (default off) replace one chat glass group with a solid fill for GPU attribution.
- Why: Apple's Liquid Glass guidance (group glass in a container, no glass on glass, honour accessibility settings) and the
  iOS chat-scroll GPU traces of 2026-11-06 (~5 "Read Surface" passes per frame).
- Where: `submodules/TelegramUI/Sources/{ChatHistoryNavigationButtons,ChatHistoryNavigationButtonNode,SharedAccountContext}.swift`,
  `submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/{GlassBackgroundComponent,GlassEnvironment,GlassDebugGroups,GlassStackHostGeometry,GlassContainerUpdateGate}.swift`,
  `NavigationBarNode.swift` and `ChatTextInputPanelNode.swift` (one `debugGroup` line each), `DebugController.swift`, `ExperimentalUISettings.swift`.
- Upstream: `ChatHistoryNavigationButton*` and `GlassBackgroundComponent.swift` are upstream files (the container, the view init and `update` changed in a few places); the rest is new.
- Sync: re-apply the container hosting if upstream changes how `ChatHistoryNavigationButtons` adds its buttons.
- Not done: replacing Telegram's navigation bar, tab bar or edge effect with system ones, and the iOS 26 luma clamp, are owner decisions.

### Chat-scroll experiments (iOS, Debug Settings, default off)
- What: two switches under Debug Settings ▸ Chat scroll. "Chat rows: prepare layout ahead" builds the rows just beyond the loaded
  edge of the CoreList chat on a background queue and uses a result only for an exactly equal key. "Chat rows: reuse row views"
  tears unloaded rows down at an idle run-loop turn and pools the sticker row view. Both off: today's code paths.
- Why: the owner's chat-scroll traces of 2026-11-06 (row build 29 % of main during scroll, text layout ~220 ms, row teardown 76 ms).
- Where: new module `submodules/TelegramUI/Components/Chat/ChatRowPrep`; `CoreListChatRowPrefetcher.swift` and
  `CoreListChatHistoryBackend.swift`; `CoreVirtualListView.rowRetirementHandler` / `releaseRetiredRow` / `currentContentWidth`;
  `ChatMessageItemView.supportsRowReuse` / `prepareForRowReuse` (sticker row overrides them);
  `ChatMessageItemImpl.resolvedItemViewClass()` (the former inline class choice); `ChatControllerInteraction.rowPrepEpoch`
  (`didSet` on the properties a row's layout reads); `ExperimentalUISettings.chatScrollExperiments`; `DebugController.swift`.
  Also `Display/TransformImageNode.resetArguments()` (new, used by the pooled sticker row) and `ChatMessageStickerItemNode` (placeholder removal by node, new `dateAndStatusNode` on reset).
- Upstream: `ChatMessageItemImpl`, `ChatMessageItemView`, `ChatMessageStickerItemNode` (the `firstTime` closure variable became a
  member) and `ChatControllerInteraction` are upstream files with small changes; the rest is new. Not shared with the Mac (CoreList is iOS only).
- Sync: a property added upstream to `ChatControllerInteraction` that a row's layout reads needs the `rowPrepEpoch` `didSet`; a
  property added to `ChatMessageStickerItemNode` needs a ledger entry and a reset in `prepareForRowReuse` (the ledger test fails otherwise).
### Differences added or changed by the 13.2 merge (2026-11-06)
- rlottie: upstream removed it and `LottieSettings`; iOS now renders only with tlottie. Our rlottie fork and `submodules/rlottie` wrappers stay for the macOS app and the Watch app (`docs/mac-core-paths.txt`). Upstream: no.
- Glass: native adaptive look on iOS 26 and 27. The luma clamp (Telegram's fixed look) is not installed unless Debug Settings "Glass: Telegram fixed look" is on (default off; `NSUserDefaults` `nanogram.glass.telegramFixedLook`, applies at next launch). With it on: iOS 26 keeps the fixed ranges (light 0.8/0.801, dark 0/0.15), iOS 27 upstream's adaptive ones. With it off `registerEffectViewOverrides` does no class lookup on iOS 27. Where: `GlassFixedLook`, `GlassBackgroundView.adaptiveLumaRange`, `UIViewController+Navigation.m`. Upstream: differs; the bubble-free static glass assets were captured with the clamp on. Sync: keep the early return and the `wantsLumaClamp` gate when merging upstream's loop.
- HLS: upstream's native player replaces the JS player we had optimised; our zero-copy `MediaBoxRanges` parts are still read by the FFmpeg reader (with `startAt`), but the native part store writes temp files (open: use our parts for cached segments).
- State sync: the `State/Sync/` layout is upstream's. We differ in four small places inside it: `applyUpdateChannelState` writes nothing when the pts is unchanged and `applyUpdateMessageImpressionCount` writes nothing unless the view count grows (`UnchangedStateUpdates.swift`; the equal participants-count skip sits in `AccountMutableState.mergeChats`); and the `StaleChannelDiagnostics` log hooks (`UpdateInterpreter+Channels`, `ChannelPolling.pollChannelOnce`, `DifferencePolicy.applyDifferenceAnswer`). Nothing changes what is sent to the server. Sync: expect small conflicts in those three Sync files.
- History-fill confirmation: upstream's 200-id `messages.getMessages` is unchanged, but ids left out of a short answer (fewer entries than ids asked, no `messageEmpty`) stay stored and their hole is reopened (`StoredMessageConfirmation.unconfirmed`); upstream deletes them.
- Kept removed (ours): in-app updater, AppCenter, notification content extension, share-to-Telegram-team crash log.
- Debug Settings: upstream's seven new "legacy"/trace switches added to our curated list; widget debug tools, pts-limit override and remove-models not taken.
