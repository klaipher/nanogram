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
  caches, cache cleanup after build commands. SHARED-APPLE-CPU-1 outline atomics: resolved by the iOS 26.0 floor (inline LSE atomics,
  `tools/dev/tests/test_min_os.py`); `-moutline-atomics` does not link on Darwin (helper symbol names differ), so never add it.
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
  external-link login-part check (`UrlWhitelist`), WebRTC CVE fixes.
- Why: owner's security review (2026-11-04); remote DoS and key-handling findings.
- Where: `Telegram/entitlements.bzl`, `submodules/BuildConfig`, `submodules/HardenedMedia`, `third-party/libprisma`, `submodules/UrlWhitelist`, `.bazelrc`, `third-party/webrtc` (fork).
- Upstream: partly (libprisma and WebRTC fixes yes).
- Sync: libprisma is `desktop-app/libprisma` 94640c6 plus `TokenizeStats`/`TokenizeLimits`; re-add those hooks on refresh.

### Message widgets (13.2) gates
- What: upstream's message widgets (a bot's HTML/CSS/JS run in the app process) are on by default there, switched off only by the server. Here they also stop when Lockdown Mode is on (`HardenedMediaPolicy.allowsMessageWidgets`) and by a local Debug Settings switch (default off since 2026-11-11: Telegram 13.2's widget engine has a published zero-click remote code execution, tg-widget-rce; key `nanogram.messageWidgets.enabled.2`, so an earlier "on" does not carry over); the widget wallet is off behind a second Debug switch (default off) until tested on a device with a funded wallet; a crash sentinel (`MessageWidgetCrashSentinel`) makes a source that was running when the app last crashed start stopped (the static "Widget stopped" badge) for 7 days.
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
- - SwiftMath (W7): iOS `third-party/SwiftMath` is the single tree; the Mac's hardening (parse depth, table limits, authoring API, render size caps) was ported here first. Sync: the Mac Package.swift points at these sources and reads fonts from `submodules/TelegramUI/Resources/Fonts` (byte-identical to its old copy).
- - VP9Hardware (W7): the Mac references `submodules/AnimatedStickerNode/VP9Hardware` for the decoder, demuxer, both tests and the two WebM fixtures; its sticker reader (`VP9HardwareStickerReader`) stays Mac-only on `YuvConversion`.
- - QR Studio (W7): shared logic in `submodules/TelegramUI/Components/QrStudioLogic` (source set; iOS and Mac compile the same files); views, look colours and sticker decoders stay per app. Sync: a change in QrStudioLogic needs the Mac core bump and a Mac build.
- - SceneEffects (W7): the Mac uses the iOS DiamondGeometry, DiamondAnimation, both Metal sources and LiquidGlassSurfaceReleasePolicy; views and Metal bundle glue stay per app.
- - Shared libraries final state (W6): `shared/shared-libraries.json` has one source and one commit per library; BoringSSL is the klaipher/boringssl fork submodule. The Mac copy of `docs/mac-core-paths.txt` and `native-libs.json` must equal these files byte for byte at the core pin.

### Calls (tgcalls, WebRTC forks)
- What: tgcalls runs from `klaipher/tgcalls` `nanogram-shared` (iOS and Mac in one implementation), WebRTC from
  `klaipher/webrtc` `nanogram` (one pin for all three apps), runtime switches (`CallsRuntimeSwitches`), CallKit/Siri call-back fixes,
  Phone Recents switch.
- Where: `submodules/TgVoipWebrtc/`, `third-party/webrtc/`, `.gitmodules`. Records of the forks live in the forks.
- Third-party under WebRTC (W5.3): abseil is the official LTS 20260817.0 (Bazel module `abseil-cpp`, MODULE.bazel + .bazelignore, the checkout is the fork's `third_party/abseil-cpp`); libsrtp (v2.5.0), crc32c, pffft, rnnoise-vad and fft4g come from the fork's `third_party/` and `common_audio/third_party/`; only `third-party/webrtc/config/crc32c/crc32c_config.h` is iOS glue. Sync: bump the fork pin, nothing else to port; if Apple Clang rejects abseil's lifetimebound use the fork's `nanogram/apply_abseil_workaround.sh`.
- Upstream: partly. Sync: `submodules/TgVoipWebrtc/CLAUDE.md` (one `nanogram-shared` branch, three pins; the iOS bridge is the fork's `ios/` directory). Both forks contain Telegram 13.2's engine changes (webrtc 590a8b23 merged; tgcalls c1de0882 ported, see the forks' NANOGRAM-CHANGES.md); the superproject BUILD carries Telegram's `content_negotiation_test` and `signaling_sctp_options_test`. tgcalls pin: 7afc0b25 (73cc1f8d plus upstream defea4a, empty ssrc groups skipped).

### Rust MTProto engine, network
- First-response timeout (MtProtoKit, 2026-11-08): a fresh direct TCP connection waits max(3 s, 10 × its setup time) for its first
  byte instead of upstream's fixed 12 s (`MTTcpResponseTimeoutPolicy`, `MTTcpConnection`). Shared with the Mac. Upstream: 12 s.
  Sync: keep the `_connectStartTime` / `_connectDuration` / `_receivedAnyData` bookkeeping and the policy call when merging MTTcpConnection.
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
  Gift grids (store, profile, options) cache their animations at the pixels the cell shows, not four pixels per displayed point,
  and start the conversion only for a cell that stays 0.35 s (`AnimationCacheWritePolicy`; upstream converts at
  once at 2x the displayed size); Postbox stores a preference or cache entry only when its bytes changed and checkpoints
  the WAL at 3000 frames (upstream: SQLite's 1000), `journal_size_limit` 24 MB.
- Where: docs/subsystems/media-io.md, docs/subsystems/media-decode-and-voice.md, docs/performance/.

- Chat photos decode complete JPEGs at the drawn size (`ImageDecodeSizing`, used by `PhotoResources`), the photo picker issues thumbnail requests off the main thread, and `ChatHistoryListNode.processDisplayedItemRangeChanged` caches its whole-history scan per history view (all three differ from upstream; round 3, iOS UI performance).

- The new photo picker grid (MediaGrid, Telegram 13.2) runs with the iCloud thumbnail lane off, a background thumbnail filler that runs only while a library picker is open (foreground, not in Low Power Mode or at serious thermal state, 4 requests at a time), a 60,000 thumbnail cap on the store, requests issued off the main thread, a single image delivery for cells under 512 px, and a store that Storage Usage's "Clear cache" empties; upstream's grid runs unpaced with the iCloud lane on (`MediaGridPhotoLibraryServices.applyAppPacing`, `ThumbnailFillPacing`).
- Request de-duplication (2026-11-08, shared core): `photos.getUserPhotos` / chat-photo `messages.search` for the avatar gallery are shared between concurrent callers, kept 60 s (dropped at once when the peer's photo changes or the account edits a profile photo) and paused after a FLOOD_WAIT; the profile photo signal no longer restarts on presence/typing peer-view updates. Upstream sends one request per peer-view emission. Generic helper: `RequestCoalescer` (TelegramCore/Sources/Utils).
- Poll results (2026-11-08, shared core): an unchanged open poll that re-enters a chat view within 60 s of its last `getPollResults` is not fetched again at once (upstream fetches on every entry). The 30 s refresh while a poll stays visible and user actions (vote, voters list) are unchanged.
- Wallet requests (2026-11-08, Nanogram wallet, shared core): the automatic TON Connect session refresh on foreground runs at most every 5 minutes unless a wallet screen is open; a `WALLET_UNAVAILABLE` answer is remembered across launches for 5 minutes (a visible wallet screen asks at once). Not in upstream (the wallet is a Nanogram feature).

### Chat features
- Round video transcription collapse (upstream bug fix, 2026-11-07): a collapse during the 0.2 s expand animation no longer leaves the
  round video hidden; `InstantVideoFileTransitionGate` in `ChatMessageInteractiveInstantVideoNode` drops the stale expand completion.
  Sync: keep the token in `animateTo`'s completion and the `begin()` in `animateFrom` if upstream changes these methods.
- Gift store and gift transfer list: loading the next page from the scroll callback is dispatched to the next main-queue turn (`Queue.mainQueue().justDispatch`, upstream's own idiom in the craft and profile gift lists). Upstream calls it inline, and a scroll event during the screen's layout re-entered the update and crashed (TestFlight 202611061452). Where: `Gifts/GiftStoreScreen/Sources/GiftStoreScreen.swift`, `Gifts/GiftOptionsScreen/Sources/GiftOptionsScreen.swift`. On an upstream merge keep the dispatch.
- What: News feed, opening a channel at a post, suspicious-peer chat gate, Postbox to TelegramEngine refactor, CoreList chat history backend. (check)
- Also: always-on numbers-only diagnostics for an empty history viewport (`CoreListInvariant` log tag; `CoreList/CoreListDemo/ViewportInvariant.swift`, `CoreVirtualListView.checkViewportInvariant`, `docs/chat/corelist-chat-history-backend.md` "Empty-viewport diagnostics"). Logging only, no behaviour change.
- Where: docs/subsystems/channel-post-and-news-feed.md, docs/subsystems/suspicious-peer.md, docs/chat/.
- Context-menu reaction with the keyboard up lands through the chat's standalone animation (menu in the keyboard window cannot show the flight). Where: `ContextReactionLandingRoute.swift`, `ChatContextReactionStandaloneLanding.swift`. Upstream: no.

### Platforms
- What: iPad (resizable chat list, window controls, Split View cameras), iPhone Duo reserved corners, iOS 26/27 window and touch handling, standalone Apple Watch client.
- Where: docs/iphone-duo-layout.md, docs/ios27-windows-and-touches.md, `Telegram/WatchApp`.
- iPad floating keyboard in a floating window: upstream reserves the floating keyboard's height inside a Slide Over / windowed app (input panel lifted, empty area below);
  ours reserves height only for a docked keyboard that overlaps the window. Where: `TabletLayoutRules.swift` (`tabletWindowedKeyboardHeight`), `WindowContent.swift` keyboard handler.
- iPad display link: upstream always runs the shared display link at up to 120 Hz on an iPad; ours asks only for the rate the active
  animations need, as on the iPhone (always; its Debug Settings switch was removed on 2026-11-08). Where:
  `TabletEnergyRules.swift` (`sharedDisplayLinkFrameRateRange`), `SharedDisplayLinkDriver` (`DisplayLinkAnimator.swift`).
- iOS 27 glass backdrop overrides: `registerEffectViewOverrides` (`UIViewController+Navigation.m`) skips the `UISDFBackdropView` lookup on iOS 27 (upstream 13.1.2 looks it up by the iOS 26 name, misses, and pays a failed mangled-name scan of about 45 ms in +load). Still true: one lookup per OS, by the running OS's name.

### Branding and identity
- What: Nanogram name, icons (Sphere default), bundle names, Siri phrases, language packs; a lint keeps Telegram's name and logo out. Own bundle identifiers and team.
- Where: `tools/dev/lint/branding.py`, `Telegram/Telegram-iOS/Nanogram.icon`.
- Also: the app bundle and executable are `Nanogram.app` / `Nanogram` (`Telegram/BUILD` `bundle_name`, 2026-11-08); the Bazel target and `Telegram.ipa` keep upstream's name.
- Upstream: no.
- Also: own URL scheme `nanogram://` (2026-11-15, owner request: launchers such as one sec open Nanogram even when official Telegram, which also claims `tg://`, is installed). `Telegram/BUILD` registers it as a third URL type; `NanogramAppScheme` (NanogramFeatures) makes `AppDelegate.openUrl` treat a bare `nanogram://` as "bring the app up" and `nanogram://x` as `tg://x`, so the scheme is never handed back to iOS (which would reopen the app).

### Call switch defaults (iOS)
- What: livestream hardware decoding, native camera frames, system noise suppression, the thermal video ladder and group
  noise = RNNoise only are on by default and stay switchable in Settings > Nanogram Features; each has a new storage key so earlier saved
  values do not count. Advanced ducking (other apps' audio may reach the peer; unchecked on a call), the reference engine, VoIP TCP
  and on-device translation stay off.
- Why: owner decision, 2026-11-06 (measured wins, local only, nothing on the wire).
- Where: `submodules/TelegramUIPreferences/Sources/ExperimentalUISettings.swift`, `docs/subsystems/tgcalls/call-switches-and-review-fixes.md`.
- Upstream: no (the switches are ours).
- Behaviour: no model cache (the previous renderer's cache was keyed by file name), so each load re-parses; simulator slice is aarch64 only; compile action needs rustup and network on a cache miss. Sync: none.

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
  `submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/{GlassBackgroundComponent,GlassEnvironment,GlassDebugGroups,GlassStackHostGeometry,GlassContainerUpdateGate,GlassMemberVisibility}.swift`,
  `NavigationBarNode.swift` and `ChatTextInputPanelNode.swift` (one `debugGroup` line each), `DebugController.swift`, `ExperimentalUISettings.swift`.
- Upstream: `ChatHistoryNavigationButton*` and `GlassBackgroundComponent.swift` are upstream files (the container, the view init and `update` changed in a few places); the rest is new.
- Also: a hidden floating button gives up its glass (`GlassBackgroundView.update(isVisible: false)`, state in `GlassMemberVisibility`), because the shared container draws a member that is only faded or scaled down (a visible dot that merged with the visible button).
- Sync: re-apply the container hosting if upstream changes how `ChatHistoryNavigationButtons` adds its buttons.
- Not done: replacing Telegram's navigation bar, tab bar or edge effect with system ones, and the iOS 26 luma clamp, are owner decisions.

### Chat-scroll, chat-open and emoji-panel behaviours (iOS, always on since 2026-11-08)
- Default: owner decision 2026-11-07 after using them on device, then the Debug Settings switches were removed on 2026-11-08 (measured on device: ours won or tied): prepare layout ahead, reuse row views, defer non-visible chat-open setup and the emoji panel deferral (first-responder handoff and heavy GIF layers) are now always on. `ExperimentalUISettings.chatScrollExperiments`, `chatOpenDeferSetup` and `emojiPanelDefersHeavyWork` and `ChatScrollExperiments` / `EmojiPanelOpenTuning.setDefersHeavyWork` no longer exist.
- What: "prepare layout ahead" builds the rows just beyond the loaded
  edge of the CoreList chat on a background queue and uses a result only for an exactly equal key. "Reuse row views"
  tears unloaded rows down at an idle run-loop turn and pools the sticker row view.
- Why: the owner's chat-scroll traces of 2026-11-06 (row build 29 % of main during scroll, text layout ~220 ms, row teardown 76 ms).
- Where: new module `submodules/TelegramUI/Components/Chat/ChatRowPrep`; `CoreListChatRowPrefetcher.swift` and
  `CoreListChatHistoryBackend.swift`; `CoreVirtualListView.rowRetirementHandler` / `releaseRetiredRow` / `currentContentWidth`;
  `ChatMessageItemView.supportsRowReuse` / `prepareForRowReuse` (sticker row overrides them);
  `ChatMessageItemImpl.resolvedItemViewClass()` (the former inline class choice); `ChatControllerInteraction.rowPrepEpoch`
  (`didSet` on the properties a row's layout reads); `DebugController.swift` (switch rows removed).
  Also `Display/TransformImageNode.resetArguments()` (new, used by the pooled sticker row) and `ChatMessageStickerItemNode` (placeholder removal by node, new `dateAndStatusNode` on reset).
- Upstream: `ChatMessageItemImpl`, `ChatMessageItemView`, `ChatMessageStickerItemNode` (the `firstTime` closure variable became a
  member) and `ChatControllerInteraction` are upstream files with small changes; the rest is new. Not shared with the Mac (CoreList is iOS only).
- Sync: a property added upstream to `ChatControllerInteraction` that a row's layout reads needs the `rowPrepEpoch` `didSet`; a
  property added to `ChatMessageStickerItemNode` needs a ledger entry and a reset in `prepareForRowReuse` (the ledger test fails otherwise).
### List scroll: display link rate, deferred accessibility (iOS, no switch since 2026-11-08)
- What: the shared display link asks only for the rate its animations need (60 Hz, or 30 Hz when every link asks for 30 or less) instead of upstream 13.2's rule (`.default` for links of 60 fps or less, so up to 120 Hz on ProMotion). `ListViewDeferredAccessibility` builds row accessibility strings after rows stop arriving (immediately only while VoiceOver or Switch Control runs) instead of inside each row's layout, as upstream does.
- Why: the owner found chat-list scrolling short of 120 Hz (2026-11-07). A code comparison against 13.2 found the list engine
  identical and these two of our changes as the only ones on the scroll path; the Debug Settings A/B switches (display link rate, accessibility timing, a per-scroll pacing log) were run on device, our variant won or tied, and the switches and the pacing log (`ListViewScrollPacing`) were removed on 2026-11-08. Our variant is the only one now.
- Where: `TabletEnergyRules.swift` (`sharedDisplayLinkFrameRateRange`), `SharedDisplayLinkDriver`, `ListViewDeferredAccessibility`. Not shared with the Mac.
- Upstream: differs (as above); the upstream rule function was deleted.

### Chat list rows (iOS, always on since 2026-11-08)
- What: lazy rare subnodes (always on; the Debug Settings switch was removed 2026-11-08). A `ChatListItemNode` adds its rarely shown parts (community shadow, status, pinned / hidden-peer / muted icons, badge, mention badge, online dot) to its node hierarchy only when the row first shows them, at the same z-position as in `init`. Pixels and animations are identical.
- Why: the owner's iPhone misses frames at 120 Hz when rows enter; a CPU profile showed the row's whole subnode tree materializing views/layers on the main thread at its first `.layer` touch, and the Core Animation commit growing with layers per row (commit 1ab7a640).
- Where: `ChatListLazySubnodes.swift` (pure placement), `ChatListItem.swift` (`ChatListItemNode.init`, `showLazySubnode`, `updateLazyFrame`/`updateLazyAlpha`, `subnodeLedger`, call sites in the apply closure and `setupItem`), Not shared with the Mac.
- Upstream: differs (upstream adds every subnode in `init`).
- Sync: a child added to `ChatListItemNode.init` needs a `subnodeLedger` decision (the test fails otherwise). A new `transition.update*` or `.layer` touch of a lazy node must use the lazy helpers or follow `showLazySubnode`. Any new `avatarNode` overlay needs the `showLazySubnode(.onlineDot)` gate before it. Keep every plain write on lazy nodes.

- What (back swipe preparation): "Back swipe: prepare the previous screen" (on by default since 2026-11-08, under the storage key `backSwipePreparePreviousScreenDefaultOn`; the Debug Settings switch stays for one more build, id 148). While a screen is idle (0.6 s after it settled), the screen beneath it in the stack is laid out and drawn off the hierarchy, so the edge swipe's start inserts a ready node instead of laying it out and waiting for its drawing. One level only, freed on a memory warning. Why: a 3 ms-sampled trace showed ~70 ms in `interactivePopBegan` per swipe start. Where: Display `NavigationContainer.swift` (`schedulePopPreparation`, `preparePopController`, `bottomControllerLayout`), `NavigationPopPreparation.swift`; `ExperimentalUISettings.backSwipePreparePreviousScreen`, `DebugController.swift` (PERFORMANCE section), `SharedAccountContext.swift`. Not shared with the Mac build yet (Display is shared source, the Mac needs the same wiring for the switch).

- What (async media previews): always on (the Debug Settings switch was removed 2026-11-08). While the user scrolls the chat list, a bulk insert (more than 3 rows, e.g. paging in more chats) no longer asks its rows to decode their media previews on the main thread (`ChatListSynchronousLoadingPolicy`, `userIsScrolling`); a preview may show a placeholder for a frame. First content, folder switch and jump to top stay synchronous. Differs from upstream. Why: a 3 ms-sampled stall showed ~40 ms of `mediaGridMessagePhoto` decoding for one row on the main thread. Not shared with the Mac.

- What (row reuse): always on (the Debug Settings switch, off by default, was removed 2026-11-08). Up to 8 ordinary chat rows that left a main chat list, folder or the archive list are reset and reused for the next rows of that list instead of building new nodes. Plain rows only; swiped, highlighted, typing, animating, forum, community, edit and context-menu rows are destroyed as before.
- Why (row reuse): building a `ChatListItemNode` costs more than the 120 Hz frame budget; reuse removes that cost from the scroll path. The owner measured it on a device.
- Where (row reuse): Display `ListRowPool.swift`, `ListView.swift` (`itemNodeRemovedObserver`, `containsItemNode`, `ListViewItemNodeRemovalPolicy`), `ListViewItemNode.swift` (`prepareForPoolReuse`, `poolResetLedger`), `ImageNode.swift` (`prepareForReuse`, `reuseLedger`); `AvatarNode.swift` (`prepareForReuse`, ledgers); `PeerPresenceStatusManager.cancel()`; ChatListUI `ChatListRowReuse.swift` (facts, refusals), `ChatListItem.swift` (`rowReuseRefusal`, `prepareForRowReuse`, ledgers, `nodeConfiguredForParams` split into `configureNewNode` / `configureReusedNode`), `ChatListNode.swift` (pool, observer, drain triggers); Not shared with the Mac.
- Upstream (row reuse): differs (upstream builds a new node for every row).
- Sync (row reuse): any stored property added to `ChatListItemNode`, `ItemListRevealOptionsItemNode`, `ListViewItemNode`, `AvatarNode` / `ContentNode` or `ImageNode` needs a reuse-ledger decision (the Mirror tests fail otherwise). A new optional child or view added by the apply must be removed in `prepareForRowReuse` or refused in `rowReuseRefusal`.

### Performance, battery and log-volume fixes (iOS, 2026-11-11)
- What: back-swipe hitch windows close at the end of the swipe; the covered screen is redrawn at idle when its rows changed; unchanged chat rows keep their `stableVersion` on `allUpdated` updates (R20); only viewport rows decode photos synchronously at chat open; the delete dust snapshot is drawn at scale 1.0 and skipped above 900 pt; fling flights do not pin the sampling link to 120 Hz and do not pin the rate in Low Power Mode; chat-list media previews skip an unchanged layout; the send tap commits the keyboard autocorrection only when something is pending; "Network protocol dumps" is its own Debug Settings switch (off by default), MTContext dumps are skipped in app extensions, frame-hitch stacks are one per window; `account.getChatThemes` is not repeated for the same hash within 10 minutes.
- Why: owner's traces and the 1 GB/day write-limit reports; see CHANGELOG.md `Unreleased` for each finding.
- Where: `Display` (`NavigationHitchWindow`, `NavigationPopPreparation`, `Keyboard.swift`, `FrameHitchMonitor`), `ChatRowPrep` (`ChatRowStableVersion`, `ChatViewportLoadBudget`, `ChatDustSnapshotPolicy`), `CoreListChatHistoryBackend`, `PhysicsScrollEngine`, `ChatListMediaPreviewLayoutGate`, `DebugController`.
- Upstream: differs. Shared with the Mac (`docs/mac-core-paths.txt`): `MtProtoKit` (`MTLogging`, `MTContext.m` guards; `MTLogEnabledValue` now starts false), `TelegramCore` (`Log.swift` `logNetworkDumps`, `LoggingSettings`, `ChatThemes.swift` request gate). Everything else is iOS only.
- Sync: a new MtProtoKit dump belongs behind `MTLogEnabled()`, or `MTLogContextDumpEnabled()` when an extension loads it; a new MT line that must stay with the switch off uses `MTShortLog`.

### Incoming call ring stops when the call ends elsewhere (iOS, notification fallback)
- What: without the notification filtering entitlement an incoming call rings as the extension's notification. After delivery the extension keeps asking `phone.receivedCall` every 2 s for 30 s (the ringtone's length) and removes the ring (found by `call_id` in its userInfo) when the server says the call is over; a missed-call push or the call's service message removes only the rings of calls the server reports over (matched by call id, so a newer call from the same caller keeps ringing); a call already over is not rung; a repeated push of the same call is shown quietly; call events go to the always-on short log (`nse call ...`), which "Send Critical Logs" now includes. Upstream shows a one-shot notification with no sound and no cleanup.
- Why: declining or answering on another device sends this phone no push, so the ring lasted until the app was opened.
- Where: `Telegram/NotificationService/Sources/IncomingCallRingWatch.swift`, `IncomingCallPushPresentation.swift`, `NotificationService.swift`; `submodules/NotificationsPresentationData` (`IncomingCallNotifications`, `IncomingCallNotificationRouting`); `submodules/TelegramCore/Sources/TelegramEngine/Calls/ProbeIncomingCall.swift`; `DebugController`.
- Upstream: differs. Shared with the Mac (`docs/mac-core-paths.txt`): only the new `ProbeIncomingCall.swift` in `TelegramCore`, which the Mac does not use.
- Sync: the watch lives on the notification branch of `IncomingCallPushPresentation.present`; with CallKit (filtering entitlement) it is never started and CallKit ends the call from the app's connection. Keep it that way when merging upstream changes to the extension's call branch.

### Notification tone "None" still vibrates (iOS)
- What: with a chat's or category's tone set to None, a message push gets the bundled near-silent `nanogram-none-haptic.caf` as its sound, so iOS fires the Taptic Engine (per Settings, Sounds & Haptics). Upstream shows no sound and no vibration. Only when our own settings resolve to None and notifications are on; muted chats, "Send without sound", reactions, stories, calls and pushes that already carry a sound are unchanged.
- Why: iOS vibrates only for a notification that has a sound, and the server omits `sound` for None.
- Where: `Telegram/NotificationService/Sources/NoneToneHaptic.swift`, `NotificationService.swift` (`processAction`, lookup before the action switch), `Telegram/Telegram-iOS/Resources/notifications/nanogram-none-haptic.caf`; tests `Telegram/NotificationService/Tests/NoneToneHapticTests.swift`. iOS only.
- Upstream: no (could be offered). Nothing changes what is sent to the server.
- Sync: the action block in `NotificationService.swift` is wrapped in a closure without re-indenting; on a conflict keep upstream's block and re-wrap it.

### Chat camera hand-off enables the preview and starts the camera (iOS)
- What: tapping the attach-menu camera tile turns the shared preview back on and starts the camera unless the tile itself had started it, before the full-screen camera takes both; upstream left the preview off when Power Saving had disabled the tile's live preview, and left the camera stopped when the tile was tapped before it first came on screen (frozen picture in both cases).
- Where: `submodules/TelegramUI/Components/ChatMediaSend/Sources/MediaPickerCameraCell.swift` (`mediaPickerChatCameraHandOff`), `submodules/MediaPickerUI/Sources/MediaPickerScreen.swift` (`cameraTapped`).
- Upstream: no (upstream bug, 13.2).

### Attach menu performance and battery (iOS)
- What: the chat camera tile creates its camera on the first start or tap; the thumbnail filler pauses while the picker is covered (editor, camera, minimized); the editor reads a caption saved on focus loss without keyboard autocorrection (`captionWithoutAutocorrection`, optional on `TGCaptionPanelView`) and the covered picker defers its selection relayout; the shared MediaGrid store, launch images and filler index are released after the last picker; the whole-library catalog pass runs at utility QoS after the first 4,096 items; the album list is built when the albums menu opens; `TGMediaEditingContext` opens its disk cache and creates directories lazily; `[FrameHitch]` windows attachGridScroll, attachGridZoom, attachEditor, camera.
- Where: `submodules/MediaPickerUI/Sources/` (`MediaPickerScreen.swift`, `MediaPickerMediaGridHost.swift`), `submodules/TelegramUI/Components/{ChatMediaSend,MediaGridPhotoLibrary,MediaGrid,ChatMediaEditorScreen,LegacyMessageInputPanel,CameraScreen}`, `submodules/LegacyComponents/Sources/TGMediaEditingContext.m`, `TGPhotoPaintStickersContext.h`.
- Upstream: no. Details: CHANGELOG.md, Unreleased.
- Sync: expect conflicts in `MediaPickerScreen.swift` (camera creation, groups, `hasGallery`) and `TGMediaEditingContext.m`; keep upstream's logic and re-apply the lazy creation.

### Shared native libraries come from one source (W1.1, iOS)
- What: libraries that Android also builds are submodules of the same upstream or klaipher fork at the same commit instead of vendored copies (proofs: docs/shared/w1-1-identity-proofs.md). Mac gets them through the core pin.
- Upstream: no (layout only; sources are byte-identical to the old copies except where listed).
- FFmpeg: `submodules/ffmpeg/Sources/FFMpeg/ffmpeg-9.0.2` = klaipher/FFmpeg `nanogram` d84c50bc (also Android's). Only source differences from the old copy: Android's `libavcodec/hevc/hevcdec.c` and `libavutil/encryption_info.c` fixes.
- boost_regex: `third-party/boost_regex/regex` = boostorg/regex boost-1.92.0 (7760ef2a); headers byte-identical to the old vendored copy.
- WAMR: `third-party/wamr/wamr` = bytecodealliance/wasm-micro-runtime WAMR-2.4.5 (25bd7eb6). Sources byte-identical to the old vendored subset; the BUILD compiles the same files.
- ogg: `third-party/ogg/ogg` = xiph/ogg v1.3.6 (be05b13e); the generated `config_types.h` is the only local file (`third-party/ogg/overlay/ogg/`).
- opusfile: `third-party/opusfile/opusfile` = xiph/opusfile v0.12 (a55c164e). The old copy's only local edits were three include paths, replaced by BUILD `include_prefix` and `//third-party/opus:opus_flat_headers`. `submodules/OpusBinding/Sources/opusfile` is a separate in-tree copy (open item).
- libwebp: `third-party/webp/libwebp` = webmproject/libwebp v1.6.0 (4fa21912); old vendored copy byte-identical except CRLF in `gradlew.bat`.
- td: `TdBinding/SharedHeaders` (a copy of td headers) is gone; `TdBinding/Package.swift` reads `../td/tde2e` from the `third-party/td/td` submodule.
- boringssl: dead `aes_ige.c` deleted (unreferenced).

### Shared native libraries, stage 2: forks and submodule swaps (W2.I1, iOS)
- What: libraries that carry Nanogram changes now come from ONE klaipher fork branch (or one official pin) that Mac and Android pin as well; the vendored copies are gone (proofs: docs/shared/w2-i1-identity-proofs.md). Mac gets them through the core pin.
- Upstream: no (layout only; sources are byte-identical to the old copies except where listed).
- shared/: submodule `shared/` = klaipher/nanogram-deps (private, `main`, 6a07ce57) holds the manifest `shared-libraries.json`, `check_shared.py`, `parity.py` (now knows `pin ... android=` and the `lib` directive), the cache policy, `feature-parity.md` and `development-pipeline.md`. `tools/dev/parity/parity.py` and `tools/dev/native/check_shared.py` are thin wrappers; the tglint pre-push hook runs `check_shared.py --side ios`. `tools/dev/cachegc/cache-policy.json`, `docs/feature-parity.md` and `docs/development-pipeline.md` are deleted here (read `shared/...`); the parity `mirror` line for feature-parity.md is gone.
- OpusBinding: its second, older in-tree copies of opusfile (an old pre-0.12 snapshot) and ogg (1.3.2 era) under `submodules/OpusBinding/Sources/{opusfile,ogg}` are deleted; the module depends on `//third-party/opusfile` (v0.12) and `//third-party/ogg` (v1.3.6), the single sources. The old copies had no Nanogram edits beyond include paths (`"opusfile/opusfile.h"`, `<opus/opus_multistream.h>`), which `include_prefix` and `opus_flat_headers` now provide. Package.swift (Mac) reads them through symlinks in `SwiftPMLinks/`. Behaviour change: current opusfile bug fixes (e.g. 32-bit read overflow checks).
- native-libs.json: probes for ogg, opusfile, boost-regex and WAMR (version read from the submodule files or the BUILD comment), on both sides (the Mac reads them through `submodules/telegram-ios/`).
- libprisma: BUILD compiles with `-DBOOST_REGEX_MAX_BLOCKS=1536` (the library and its host test), the value Android already uses; it bounds boost regex's recursion memory so a hostile code block cannot exhaust it.
- openh264: `third-party/openh264/openh264` = klaipher/openh264 `nanogram` 3583f617 (v2.7.0 + levels 6.0-6.2 + subcodec sprite mode). All 432 files of the old vendored copy are byte-identical to the fork tree. BUILD paths are `openh264/...`; the public headers keep the include path `third_party/openh264/src/codec/api/wels/` (`include_prefix`). Subcodec's symlink, CMake and CLAUDE.md point at the submodule.
- rnnoise: `third-party/rnnoise/rnnoise` = klaipher/rnnoise `nanogram` d2d79970 (xiph v0.2 + portability headers, denoise.c hardening, trimmed model). `cmp` shows all 29 source files, `rnnoise.h` and COPYING of the old copy identical to the fork. BUILD globs `rnnoise/src` (minus the three tools with `main`), header `rnnoise/include/rnnoise.h`, same 3 symbol renames.
- libprisma: `third-party/libprisma/libprisma` = klaipher/libprisma `nanogram` c061944d. The core (`libprisma/`), the grammar data and ONE `apple/Syntaxer` (iOS and macOS, replaces both copies) come from the fork; the BUILD maps `libprisma/Syntaxer.h` with `include_prefix`, bundles the fork's grammars.dat (byte-identical to the old Resources file) and keeps `SyntaxHighlighterRecursionTests` in this repo. New in the fork: Android's per-move regex budget, weak tree pointers, `searchesToGiveUp` (both budgets kept), so highlighting hostile code blocks is bounded in time as well as depth.
- SQLCipher: `submodules/sqlcipher/amalgamation` = klaipher/sqlcipher-amalgamation `nanogram` 9948d5af (tag v4.20.0-nanogram1, SQLCipher 4.20.0 / SQLite 3.54.1). `sqlite3.c` and the three headers are byte-identical to the old vendored files; BUILD and Package.swift keep all defines and the `<sqlcipher/sqlite3.h>` include path. Android takes the same amalgamation (codec on against BoringSSL, no key).
- Unneeded-code cleanup (2026-11-15): two branded RMIntro PNGs that were never bundled are back to upstream (shipped copies are in `Resources/intro`), and the twidget Cocoa shim is gone (the fork guards its imports). Both remove sync conflicts and diffs.
- QuickJS: `third-party/quickjs-ng/quickjs` = klaipher/quickjs `nanogram` f6fc68b9 (TelegramMessenger/quickjs b526a817 + the widget runtime's host API: auto-init properties, class prototypes on first use, string access, host-class global, host time and randomness, memory-limit hook, `JS_SetStopped`, dumps only on request). One engine for iOS, macOS and Android. The shim, `BUILD` and the C tests stay here; `JSInterruptHandler` now takes the `JSContext*`. VENDOR.md is a pointer to the fork's NANOGRAM-CHANGES.md.
- widget-sandbox: `third-party/widget-sandbox/widget-sandbox` = klaipher/widget-sandbox `nanogram` 1b21a48e (Telegram v0.6.3 line + Mac remote engine; nested QuickJS = klaipher/quickjs). Replaces the vendored v0.5.0 subset. Ours stay: BUILD, `WidgetSandboxIntl.swift`, the three policy test hosts. The runtime still enforces v0.5.0-era limits where v0.6.x tightened them (paint, nodes, canvas commands, layout-query count); see `third-party/widget-sandbox/VENDOR.md`.
- Widget painter: `LayerTreePainter` draws at most 16 nested filters (`kMaxNestedFilters`, `canNestFilter`); deeper filters draw their content unfiltered (a backdrop's source replay continues the outer count), as widget-sandbox v0.6.5 `paint-filter-depth` asks of clients. Ours; upstream's iOS client has it in the engine's paint limit.
- twidget and gumbo: `third-party/twidget/twidget` = klaipher/twidget `nanogram` a4f5391c (Android line 4769d72 + Mac cc044e7b + the iOS litehtml and Apple-layer edits; the fork's NANOGRAM-CHANGES.md says which of the 91 edits are carried, adapted or dropped). gumbo (13 limit changes) is the fork's `litehtml/src/gumbo`, byte-identical to the old `third-party/gumbo/{src,include}`. Behaviour differences from the old copy: bidi through the fork's own `reorder_bidi` (edit 47 not carried), calc through the fork's expression registry (48, 49, 56), the fork's `<use>`/var() handling (57, 58); the fork's Apple layer adds the Mac renderer's paint cache, patch and selection APIs, unused here.
- wallet-engine: pinned to klaipher/wallet-engine `nanogram` 44ae85c7 (was i582/wallet-engine e59e0d89): adds TON Connect envelope encrypt/decrypt, NFT transfer preparation and key rotation preview with both delivery forms (from Android's fork). iOS behaviour is unchanged: the encrypted-comment recipient key is still verified by default (`trust_recipient_public_key` is an opt-in that iOS never sets). No dependency change.
- libyuv: `third-party/libyuv/third_party/libyuv` (same path) = klaipher/libyuv `nanogram` 947f5326 = upstream 0b8dd231 (version 1977) minus `BUILD.bazel`, `WORKSPACE.bazel` and `libyuv.bzl`. Blob ids of the old copy equal upstream's (0 differing); the BUILD is unchanged. Android and Mac move to the same commit in their stages.
- BoringSSL: `third-party/boringssl/src` = klaipher/boringssl `nanogram` 1c764cec = upstream tag 0.20261105.0 (3dc4b638, API version 45; was the vendored 2ea3200c, API 43) minus every Bazel file that makes a package or repository boundary. `third-party/boringssl/BUILD` and `BUILD.generated.bzl` are unchanged in logic (upstream's util.bzl flags did not change; the new .cc files, the removed ones and the asm lists come through `src/gen/sources.bzl`). Android takes the same commit. The Mac keeps OpenSSL. Not built.
- Deleted vendored libraries (2026-11-14): `third-party/libjxl`, `third-party/XMLCoder` and `third-party/Swift2D` are gone (upstream still ships them; nothing links them). `upstream-sync.json` `removed_libraries` lists them and `sync.py` names any file a release changes there; delete such files again after the merge. Upstream: no. Sync: delete again if a merge re-adds them.
- BoringSSL: `third-party/boringssl/src` = klaipher/boringssl `nanogram` 1c764cec = upstream tag 0.20261105.0 (3dc4b638, API version 45; was the vendored 2ea3200c, API 43) minus every Bazel file that makes a package or repository boundary. `third-party/boringssl/BUILD` and `BUILD.generated.bzl` are unchanged in logic (upstream's util.bzl flags did not change; the new .cc files, the removed ones and the asm lists come through `src/gen/sources.bzl`). Android takes the same commit. The Mac now builds this same source with CMake (core-xprojects/boringssl in the Mac repository); the Mac OpenSSL 3.5.9 is gone. `submodules/OpenSSLEncryptionProvider/Package.swift` defines `TELEGRAM_USE_BORINGSSL` for the Mac. Not built.
- nanogram-rust lock (2026-11-14): `third-party/nanogram-rust/Cargo.lock` is seeded from the merged locks with no downgrades against any of the three source locks (mtproto-engine da4b2170, wallet-engine 44ae85c7, tlottie 92df98dc). Version deltas against mtproto-engine's own lock, which iOS keeps using: flate2 1.1.10 to 1.1.11 and crc32fast 1.5.2 to 1.5.5 (both newer, taken from the merged lock); bitflags 2.13.1 to 2.13.2, cc 1.4.2 to 1.4.7, cfg-if 1.0.4 to 1.0.5, find-msvc-tools 0.1.10 to 0.1.13, log 0.4.33 to 0.4.34, rustix 1.1.4 to 1.1.5 and unicode-ident 1.0.24 to 1.0.26 are raised to mtproto-engine's versions (the first draft had them lower, a downgrade for mtproto-core and mio). Checked with `cargo check --locked --release` in scratch.
- Upstream sync knows the moved libraries (2026-11-14): `tools/dev/upstream-sync/upstream-sync.json` `moved_libraries` maps the paths upstream still vendors (FFmpeg, openh264, rnnoise, libprisma, sqlcipher, libyuv, quickjs, widget-sandbox, twidget, webrtc third_party, ogg, opusfile, webp, boost_regex, wamr) to our fork branch or official pin; `sync.py` names the fork to patch for every file a release changes there. Upstream: no (our tooling). Sync: none.
- QuickJS and widget-sandbox are bumped together (2026-11-14): `third-party/quickjs-ng/quickjs` and the QuickJS nested in `third-party/widget-sandbox/widget-sandbox` (`packages/ios/Sources/CQuickJS/quickjs`) are both klaipher/quickjs 7613b6b7; keep them equal in every future bump (the manifest names both). Pins of openh264, rnnoise, libprisma, sqlcipher-amalgamation and twidget moved to the manifest's records commits. Where: `.gitmodules` gitlinks, `shared/shared-libraries.json`. Upstream: no. Sync: none.

### Differences added or changed by the 13.2 merge (2026-11-06)
- Lottie: upstream removed the C++ renderer it used before tlottie, and `LottieSettings`; iOS renders only with tlottie. Since 2026-11-11 the old renderer's submodule is gone here too: the Mac 13.2 merge dropped it as Telegram for macOS 13.2 did, so neither app builds it, as upstream. The Watch app kept a vendored copy until 2026-11-14, when it moved to tlottie too (next entry). Upstream: yes.
- Watch app stickers use tlottie, the phone's renderer (2026-11-14): the old vendored renderer package (Samsung v0.2 + 16 security cherry-picks) is gone; `Packages/TLottieKit` renders through tlottie's C API from `submodules/tlottie/tlottie` (same pin as the phone). tlottie is built as a no_std static library for arm64_32/arm64 watchOS and the simulator with a pinned nightly and `-Zbuild-std=core,alloc` (`Telegram/WatchApp/tools/build-tlottie-xcframework.sh`, run by the Bazel compile action and `tg watch`). `Telegram/WatchApp` is also now the source (the `tgwatch` repo is not available), no longer a synced snapshot. Where: `Telegram/WatchApp/`, `Telegram/prebuilt_watchos*`, `Telegram/CLAUDE.md`. Upstream: no (Telegram has no Apple Watch client in this form). Sync: none.
- Watch app libogg and libwebp are symlinks into the phone's submodules (2026-11-14): `OpusKit`'s `COgg` links framing.c, bitwise.c, crctable.h and ogg.h of `third-party/ogg/ogg`; `WebPKit`'s `WebPCore` links 133 files into `third-party/webp/libwebp` (same commits and bytes; the hand-written config.h files stay). libopus 1.6.1 in `OpusKit/Sources/COpus` is linked the same way into `third-party/opus/opus` (312 files; config.h stays hand-written). Where: `Telegram/WatchApp/Packages/{OpusKit,WebPKit}`. Upstream: no. Sync: none.
- Glass: matches upstream 13.2 by default (owner decision, revised). The luma clamp is installed on iOS 26 and 27 with upstream's ranges (`GlassBackgroundView.adaptiveLumaRange`: dark 0-0.874; light 0.22-1.0 on iOS 26, 0.125-1.0 on iOS 27). The Debug Settings switch for Apple's fully native glass was removed on 2026-11-07 (owner: it saves no battery; the clamp is one number per luma callback), so the clamp is always installed. Where: `GlassFixedLook`, `UIViewController+Navigation.m`. Upstream: same look; the only difference is that `registerEffectViewOverrides` does one class lookup for the running OS instead of upstream's loop over both names (keeps the launch-time gain). Sync: keep the single lookup when merging upstream's loop.
- HLS: upstream's native player replaces the JS player we had optimised. Ours on top of it: the native part store plays a cached segment in place (`MediaBoxRanges` over the init and segment ranges, read by the FFmpeg reader with `startAt`; `HLSStreamingStorage.nativePartContent`), writing a temp file only for hardware AV1 (counted as `tempBoxHLS`); the playlist's byte ranges are overflow-checked and must all fit the file, the bandwidth estimate and dimensions are clamped (the Mac's 27ea951d); a muted inline video buffers 15 s ahead instead of 60 s (`hlsForwardBufferSeconds`, `HLSPlaybackController.setMaxBufferAhead`); hardware AV1 follows the device (`internal_isHardwareAv1Supported`) and the `ios_enable_hardware_av1` key is only a kill switch (present and false). Nothing changes what is sent to the server. Retry behaviour is upstream's (unbounded). Sync: keep `HLSNativePartStore`'s `MediaBox` parameter and the three `HLSVideoNativeContentNode` hooks when merging upstream's version. (The old open item, using our parts for cached segments, is closed.)
- State sync: the `State/Sync/` layout is upstream's. We differ in four small places inside it: `applyUpdateChannelState` writes nothing when the pts is unchanged and `applyUpdateMessageImpressionCount` writes nothing unless the view count grows (`UnchangedStateUpdates.swift`; the equal participants-count skip sits in `AccountMutableState.mergeChats`); and the `StaleChannelDiagnostics` log hooks (`UpdateInterpreter+Channels`, `ChannelPolling.pollChannelOnce`, `DifferencePolicy.applyDifferenceAnswer`). Nothing changes what is sent to the server. Sync: expect small conflicts in those three Sync files.

- HLS: upstream's native player replaces the JS player we had optimised; our zero-copy `MediaBoxRanges` parts are still read by the FFmpeg reader (with `startAt`), but the native part store writes temp files (open: use our parts for cached segments).
- State sync: the `State/Sync/` layout is upstream's. We differ in four small places inside it: `applyUpdateChannelState` writes nothing when the pts is unchanged and `applyUpdateMessageImpressionCount` writes nothing unless the view count grows (`UnchangedStateUpdates.swift`; the equal participants-count skip sits in `AccountMutableState.mergeChats`); and the `StaleChannelDiagnostics` log hooks (`UpdateInterpreter+Channels`, `ChannelPolling.pollChannelOnce`, `DifferencePolicy.applyDifferenceAnswer`). Nothing changes what is sent to the server. Sync: expect small conflicts in those three Sync files. Added later (perf/state-sync, 2026-11-11; none changes what is sent that upstream would send, except that byte-identical repeats are not): the read-state sync sends an accepted read mark once (`ManagedSynchronizePeerReadStates` compares operations by `PeerReadStateSynchronizationOperation.syncPayload`; new `PeerReadStatePushLedger.swift`; `SynchronizePeerReadState.pushPeerReadState` skips and records; the ledger is handed through `AccountStateManager` -> `FinalStateReplayer` -> `replayFinalState` -> `ReplayContext.readStatePushLedger` and noted in `StateReplay+ReadStates` `applyResetReadState` / `applyUpdatePeerChatUnreadMark`); read-state validation skips its `getHistory(limit: 1)` probe when a cloud message is stored (`dialogReadState`); `AccountStateEventHub.dispatch` opens no Postbox transaction when there is nothing to read; Postbox slow-view diagnostics (`combinedView(keys:file:line:)`, `ViewTracker.liveViewCountsDescription`). Sync note for upstream merges: `Sync/StateReplay.swift`, `StateReplay+ReadStates.swift` and `FinalStateReplayer.swift` carry one extra optional parameter (`readStatePushLedger`); on a conflict keep upstream's body and re-add the parameter and the two `note(...)` calls, and if upstream changes `PeerReadStateSynchronizationOperation` or the push in `SynchronizePeerReadState.swift`, re-check `syncPayload` (it must cover everything the push sends) and that the ledger still records only a push whose requests all succeeded.
- History-fill confirmation: upstream's 200-id `messages.getMessages` is unchanged, but ids left out of a short answer (fewer entries than ids asked, no `messageEmpty`) stay stored and their hole is reopened (`StoredMessageConfirmation.unconfirmed`); upstream deletes them.
- Kept removed (ours): in-app updater, AppCenter, notification content extension, share-to-Telegram-team crash log.
- Debug Settings: upstream's seven new "legacy"/trace switches added to our curated list; widget debug tools, pts-limit override and remove-models not taken.
- Lint cleanup of 13.2 lines (fix/lint-13-2): we now differ from upstream in about 100 files, only to remove force unwraps (`!`), force casts (`as!`) and trapping Int32 timestamp arithmetic that the pre-push guardrail blocks. Behaviour for valid input is unchanged. A future upstream merge will conflict on these lines: take upstream's version, then re-run `tools/dev/lint/tglint.py lint --commits origin/main..HEAD` and redo the fixes (patterns: `dict[k, default: []].append`, `Int32(clamping: Int64(x) + N)`, guard-`as?`). Files: `submodules/TelegramCore/Sources/{Account/AccountIntermediateState, State/AccountStateEventHub, State/Holes, State/Sync/{ChannelPolling, StateReplay+Finalize, StateReplay+Messages, StateReplay+Peers, StateReplay+Settings, StateReplay+StateAdvance, StateReplay+Typing, SyncSnapshot, UpdateInterpreter, UpdateInterpreter+Typing}, TelegramEngine/Messages/{ReplyThreadHistory, Stories}}.swift`; `submodules/TelegramCore/Tests/StateSync/*` (`self.baseDate + N` became `self.baseDateOffset(by: N)`, helper in `StateSyncTestCase.swift`); `submodules/Postbox/Tests/RecentlyDeletedMessagesTests.swift`; `submodules/{AvatarNode, BrowserUI, Display/Source/TextNode, InstantPageUI, MediaPickerUI}`; `submodules/TelegramUI/Sources/{ChatController, Chat/ChatControllerLoadDisplayNode, TelegramRootController}.swift`; `submodules/TelegramUI/Components/{CameraScreen, Chat/ChatMessageBubbleItemNode, ChatMediaEditorScreen, ChatMediaSend, CoreList/CoreListDemoTests, InteractiveTextComponent, MediaEditor, MediaGrid, MessageWidget, PeerInfo/PeerInfoScreen, PeerInfo/PeerInfoVisualMediaPaneNode, ShareScreen, StaticGlassBackground, Stories/StoryContainerScreen}`; `build-system/WidgetIDL`; `Tests/WidgetHarness`.

### Chat open: wallpaper pattern prewarm (iOS, always on)
- What: after launch and after each chat wallpaper change, `TelegramRootController` asks `WallpaperPatternPrewarmer` (WallpaperBackgroundNode) to render the pattern of the chat wallpaper on a utility queue into `WallpaperBackgroundNodeImpl.cachedPatternImages` (shared slot) under the key the chat looks up. The first chat open then hits the cache instead of drawing the pattern (~36 ms) on the main thread. Always on (the Debug Settings switch was removed 2026-11-08).
- Upstream: new file `WallpaperPatternPrewarmPlan.swift`; additions at the end of `WallpaperBackgroundNode.swift` (an extension of `WallpaperBackgroundNodeImpl` and `WallpaperPatternPrewarmer`); a few lines in `TelegramRootController.swift`. The pattern colour rule is duplicated from `loadPatternForSizeIfNeeded`; keep them in step on sync (a difference only makes the chat miss).
- Not done: per-chat wallpapers, iPad, landscape, plain and gradient wallpapers (nothing to render or size unknown).
- libopus builds from the xiph/opus v1.6.1 submodule (`third-party/opus/opus`, 22244de5) with CMake + Ninja, no tarball; libwebp uses Ninja (2026-11-14). The options live in nanogram-deps (`shared/opus/opus-options.sh`, shared by iOS, Mac and later Android; OSCE speech enhancement compiled in behind the opt-in "Enhance voice messages" switch, models pinned in `MODULE.bazel`), with `OPUS_PRESUME_NEON=ON` so the Mac keeps NEON; the Mac moved from fixed point to floating point (CHANGELOG.md). Where: `third-party/opus`, `third-party/webp`. Upstream: no (upstream vendors the tarball and runs configure). Sync: keep ours.

### Media UI performance experiments
- What: debug switches "Stickers: parallel queues" (animated sticker nodes over 3 serial queues) and "GIF grid: parallel decode" (per-tile decode passes), both off by default; shared `CIContext` for sticker cutouts, one Metal render command queue per device, memory-mapped reads of complete photo files, status publishing only with a subscriber.
- Where: `submodules/AnimatedStickerNode`, `submodules/TelegramUI/Components/BatchVideoRendering`, `submodules/AnimationCompression`, `submodules/PhotoResources`, `ExperimentalUISettings`, `DebugController`.
- Upstream: no.
- Sync: expect conflicts in `AnimatedStickerNode.swift` (queue, status, background gate) and `BatchVideoRenderingContext.swift`.

### Voice transcription: on-device by default (SpeechAnalyzer)
- What: tapping the transcribe button on a voice message transcribes it on the device with `SpeechTranscriber`/`SpeechAnalyzer` (iOS 26), for every account: no Premium, no trial or cooldown, no server. The file is read in place (no tmp copy). The locale's model is downloaded ahead (`prepareOnDeviceTranscription`, once per launch, when a voice message with the button is laid out; Apple's `AssetInventory`) and a tap while that download runs awaits the same download (one in-flight task per locale in `SpeechAssetInstalls`). A voice file that is not downloaded is fetched before transcribing; the trial cooldown lock is not shown when on-device transcription is on. SFSpeechRecognizer (on-device only) is the fallback for a locale the analyzer does not support. Telegram's server transcription is used only when the device produced no text and the account is Premium or the group is boosted (`shouldRetryTranscriptionOnServer`). Secret chats, view-once and previews have no button, as before.
- Switches: Settings > Nanogram Features "On-Device Voice Transcription" (the Debug Settings row was removed 2026-11-15) (default on; stored under the new key `localTranscriptionOnDevice`, so the old default-off value saved by testers is dropped on purpose); `-NanogramSpeechAnalyzer NO` forces the SFSpeechRecognizer engine.
- Privacy: audio and text never leave the device on this path; no new entitlement (the speech-recognition usage description exists). Apple docs: Speech framework (`AssetInventory`, `AssetInstallationRequest.downloadAndInstall`, iOS 26).
- Why: more accurate model, runs out of process, removes the Premium dependency.
- Where: `submodules/Media/LocalAudioTranscription`, `ChatMessageInteractiveFileNode.transcribe`, `ExperimentalUISettings.localTranscription`.
- Upstream: no (upstream keeps the copy, SFSpeechRecognizer and server-only transcription for Premium).
- Sync: take upstream's file, re-apply the in-place path and the confidence guard.

### Live location: stationary-aware updates (experiment)
- What: iOS 17+ `CLLocationUpdate.liveUpdates` backend for live location alone, behind the default `NanogramStationaryLocation` (off).
- Why: GNSS stayed powered for up to 8 h while the user was stationary.
- Where: `submodules/DeviceLocationManager` (`LiveLocationUpdates.swift`).
- Upstream: no.
- Sync: additive; re-apply the backend switch in `updateTopMode`.

### Watch app modernization (2026-11-14, branch mod/watch; every behaviour change behind a default-off switch)
- What: twelve specs from the modernization audit, for `Telegram/WatchApp`. A switch is a `UserDefaults` bool `nanogram.watch.<name>` (`WatchFeature`, `WatchFeatureFlags.swift`), so a device scheme or test run flips it with a launch argument (`-nanogram.watch.longFormAudio YES`). All off by default; the owner turns them on after a device check, then changes `WatchFeature.defaultValue`.
  - `longFormAudio` (IOS-WATCH-AUDIO-1, WATCH-AUDIO-1): music files get the long-form route policy (Bluetooth headphones through the system route picker), async activation, Now Playing and remote commands (play, pause, skip 15 s). `WKBackgroundModes: audio` is static in Info.plist (via project.yml) and therefore ships in the default build even though the flag is off: an intentional default-on declaration, App Review may ask about it. Mode is `.default` (music), not `.spokenAudio`. Voice notes, recording and video sessions are unchanged.
  - `chunkedVoiceDecode` (WATCH-MEM-1): `OpusKit.OpusChunkedDecoder` and streamed playback; first sound after about 100 ms of audio is decoded, 3 one-second buffers in flight, instead of the whole note first.
  - `offMainStickerRender` (WATCH-GPU-1): `LottieFrameRenderer` actor rasterises tlottie frames off the main actor, late frames are dropped, 24 Hz in Low Power Mode.
  - `messageWindowTrim`, `fileProgressThrottle` (WATCH-LIST-1): the open chat keeps about 120 messages; progress-only `updateFile` events reproject once per 5%. The cached sort per window revision has no switch (pure).
  - `localizedTdlibParameters` (WATCH-I18N-1): real language code, app version and OS version in `setTdlibParameters`. Server-visible; the owner decides.
  - `widgetSnapshot` (IOS-WATCH-WIDGET-1): the app writes counts and chat titles (never message text) to the App Group `group.org.klaipher.Nanogram.watch`; the widget reads them.
  - `backgroundRefresh`, `pushRegistration` (WATCH-INT-1): see below.
  - No switch: IOS-WATCH-ATS-1 (the ATS exemption is gone; nothing in the app uses URLSession), WATCH-SIMD-1 (vDSP RMS, allocation-free tap, 20 Hz meter updates), WATCH-API-1 (Double Tap on record start/stop/send and both Replay buttons; start/stop/success haptics).
- Widget (IOS-WATCH-WIDGET-1, shipped in the iOS build; remaining checks in `Telegram/WatchApp/WatchWidget/OWNER-STEPS.md`): `WatchWidgetExtension` is a target of `project.yml` and the committed `tgwatch.xcodeproj`, embedded in the watch app (`PlugIns/WatchWidgetExtension.appex`, bundle id `<watch app id>.widget`, so `org.klaipher.Nanogram.watchkitapp.widget`). The Bazel rule's bundle id now reaches xcodebuild as `TG_WATCH_BUNDLE_ID` (a `PRODUCT_BUNDLE_IDENTIFIER` override would rename the widget too). Both targets carry the App Group `group.org.klaipher.Nanogram.watch` (`WatchWidget/*.entitlements`). `prebuilt_watchos_patch.sh` signs the extension with its own profile (`--watchWidgetProvisioningProfile`, `tg` passes `WatchWidget.mobileprovision`) and the app with the group in its profile; without profiles both are signed ad hoc with the group so a TestFlight export keeps it. A signed app with no widget profile, or a profile without the group, stops with the fix. `tools/dev/device_signing.py profiles` now creates the `WatchApp` and `WatchWidget` profiles; Xcode registers the group from their entitlements. `widgetSnapshot` and `backgroundRefresh` default to on (`WatchFeature.shippedOn`; a launch argument or defaults value of NO turns one off). `backgroundRefresh` needs no portal capability and keeps the summary fresh while the app is closed (about every 30 minutes within the system budget); the cost is a short TDLib catch-up per wake. `project-widget.yml` is now only an Xcode automatic-signing overlay. Remote (Tart/darwin-containers) builds do not forward `--watchWidgetProvisioningProfile`; they resolve `WatchWidget.mobileprovision` from the codesigning material.
- Push (owner steps): `pushRegistration` registers the watch's APNs token with TDLib (`registerDevice`, a new device on the account: server-visible). It needs Push Notifications on the watch App ID, an `aps-environment` entitlement in the Bazel signing, and, to be useful, a notification service extension that decrypts Telegram payloads (shared logic with the iOS NotificationService); that extension and the foreground-presentation delegate are not written. Without them pushes arrive as encrypted placeholders.
- Why: the audit (`wt/forks/modernization/watchos.md`) found these gaps and costs; each fix is small and isolated, none was built or run here.
- Where: `Telegram/WatchApp/` (sources, `project.yml`, `project-widget.yml`, `Shared/`, `WatchWidget/`, tests under `Tests/WatchAppTests` and `Packages/OpusKit/Tests`), `Telegram/WatchApp/BUILD` and `Telegram/prebuilt_watchos_compile.sh` (the widget sources are build inputs; only `OWNER-STEPS.md` is excluded), `Telegram/prebuilt_watchos.bzl` and `prebuilt_watchos_patch.sh` (sign the widget), `build-system/Make/Make.py`, `tools/dev/tg`, `tools/dev/device_signing.py`.
- Upstream: no (Telegram has no Apple Watch client in this form). Sync: none.

### Modernization: shared core performance items (iOS and Mac, 2026-11-14)
- What: MtProtoKit AES-IGE decrypt is one fused ARMv8 AESD/AESIMC loop on arm64 (the CommonCrypto per-block code stays as `MyAesIgeDecryptReference`); first-frame cache representations complete when the decoded frame is nil or the JPEG encode fails; GraphCore `DisplayLinkService` uses a `CADisplayLink` on iOS; a failed audio-session `setActive(false)` retries through `queue.after` with a generation guard instead of `Thread.sleep(2.0)`. Dark by default (UserDefaults `nanogram.experiment.<name>`, `ExperimentalPerformanceFlags` in SwiftSignalKit): iOS ThreadPool QoS (`threadPoolQualityOfService`), iOS multi-threaded software AV1 (`softwareDecodeThreads`), VideoToolbox scrub previews (`previewHardwareDecode`). Later changes: AES key schedule cleared after use; GraphCore2 iOS branch removed (only GraphCore uses CADisplayLink); iOS AV1 threads capped by performance cores; flags mirrored into SwiftSignalKit2; first-frame JPEG classification is iOS-only (not in the Mac build); toggled by launch arguments plus relaunch, and since 2026-11-14 by the Debug Settings section PERFORMANCE EXPERIMENTS (relaunch applies) with `PerformanceExperimentStats` numbers added to Send Logs (`DebugController.swift` ids 160 to 164, `FFMpegMediaVideoFrameDecoder`, `MediaPlayerFramePreview`, `ThreadPool.swift`; tester guide `docs/testing/a15-a16-performance-experiments.md`).
- Where: `submodules/MtProtoKit/Sources/MTAes.{m,h}`, `submodules/SSignalKit/SwiftSignalKit/Source/{ExperimentalPerformanceFlags,ThreadPool}.swift`, `submodules/MediaPlayer/Sources/{FFMpegSoftwareDecodeThreads,UniversalSoftwareVideoSource,MediaPlayerFramePreview,FFMpegMediaVideoFrameDecoder}.swift`, `submodules/TelegramUI/Sources/FetchCachedRepresentations.swift`, `submodules/GraphCore/{Sources,GraphCore2/Sources}/Helpers/DisplayLinkService.swift`, `submodules/TelegramAudio/Sources/ManagedAudioSession.swift`.
- Upstream: no. Sync: expect conflicts in `MTAes.m` (keep upstream's body as the reference function), `FetchCachedRepresentations.swift` (two first-frame blocks) and `ManagedAudioSession.swift` (`applyNone`).

### iOS 26.0 minimum (deliberate difference from upstream)

- What: `minimum_os_version` is "26.0" in `Telegram/BUILD` (upstream: 15.0). Nanogram-added code (Glance widgets and activities, App Intents, the SpeechAnalyzer path and its 26.0 gate, the `Camera*Policy` files) has no iOS < 26 availability gates. Upstream-origin checks (`SharedWakeupManager` 26.0 guards, `Camera.swift` attribute, the 13.0/16.0 blocks in `LocalAudioTranscription.swift`) stay as upstream wrote them.
- Why: owner decision 2026-11-14, to use the whole baseline (A13/A12 and newer, current OS features, hardware codecs) without fallback paths.
- Upstream: no. Upstream files keep their `#available` checks; do not mass-edit them. On sync, keep this value in `Telegram/BUILD` and new upstream gates stay as they come. The Mac app is separate (macOS 15, Apple Silicon): shared code keeps its macOS paths.
- Build baseline (stream 1): `tools/dev/set-min-os.py` makes every BUILD file follow `Telegram/BUILD` (upstream test targets carry 15.0); native-library scripts (`submodules/ffmpeg/.../build-ffmpeg-bazel.sh`, `third-party/{opus,webp,libjpeg-turbo,td,dav1d,libvpx}`) use 26.0 on their iOS arms and keep macOS arms at 14.0; `.bazelrc` adds `extra_rustc_flags=-Ctarget-cpu=apple-a12` and the deprecation downgrade (`-Wno-error=deprecated-declarations`, `--@build_bazel_rules_swift//swift:copt=-Wwarning` and `...copt=DeprecatedDeclaration` (the native `--swiftcopt` was removed in Bazel 8)). The CPU is the compiler default for the 26.0 floor (apple-a12); no `-mcpu`. Do not use apple-a13 (A12 iPads lack dotprod/sha3). Watch app stays 26.0.
- Sync: after each release merge run `python3 tools/dev/set-min-os.py` and `tools/dev/tests/test_min_os.py`; expect conflicts at `Telegram/BUILD` (`minimum_os_version`), `.bazelrc` and `third-party/*/build-*-bazel.sh`. Known risk: the Swift `-Wwarning` ordering relative to `-warnings-as-errors` is unverified until the first build (rules_swift 4.2.2 appends the global copt after the target's, which is the working order); swift_strict.bzl would only cover strict modules, not the upstream ones.

### Send failures: fewer red marks, reasons in the log and the Retry menu (iOS and Mac, shared core, 2026-11-22)

- What: the red "!" (`MessageFlags.Failed`) is a final state the user clears by hand, so a transient problem must not reach it.
  (1) A send RPC (`sendMessage`, `sendMedia`, `sendMultiMedia`, forward, inline result) that fails with a negative code, a code of
  500 or more, or an engine-invented `PROTOCOL_ERROR_*` / `TL_PARSING_ERROR` / `ENGINE_SWITCHED` is sent again with the same random
  id and the already uploaded content, up to 5 tries (2, 4, 8, 16, 30 s); any other 4xx fails at once (the reference clients'
  rule). A lost file part (`FILE_PART_N_MISSING`, `FILE_PARTS_INVALID`, `FILE_ID_INVALID`) re-uploads once through the existing
  `forcedReuploadOnce` path. Paid-star messages are not repeated. (2) An upload that fails transiently starts again (new file id)
  up to 3 tries, in the same `.uploading` state, so later media in the chat keeps waiting behind it; secret chats are left out.
  (3) One `saveFilePart` that fails transiently is retried 4 times (0.5 to 4 s) by re-subscribing the same part signal (no second
  encryption transform). (4) saveFilePart requests of the multiplexed upload no longer arm the 5 s no-incoming-bytes guard
  (`pendingUploadPartsNeedTimeoutTimer`); a stall fix, it never set the failed mark itself. (5) Rust bridge: a call marked
  `NetworkEngineRequestOptions.safeToRepeat` (file parts and random-id sends) is sent again for every `PROTOCOL_ERROR_ANSWER_LOST`
  with a growing delay instead of failing after 3 (a delivered message was shown as failed and Retry posted it twice). (6) The
  Postbox launch expiry (unsent for 10 minutes becomes failed) runs only in the app's own process, not in the notification
  service, share or Siri extensions that open the same database. (7) Every failure line names the real reason, the engine kind
  and the network type, the Postbox expiry is logged, and the waiting-upload path now alerts like the direct one. (8) The Retry
  menu shows a second line from `sendErrorCode` ("Too many messages", "Not allowed in this chat", "Media rejected", "Not sent in
  time. Tap to retry." when no code was stored, "Could not send. Tap to retry."), plain English like the other Nanogram screens.
- Why: owner report (iPhone 17 Pro Max, iOS 27.2.1): photos often end red on mobile data and almost never on Wi-Fi. Upstream's
  fail paths needed a definitive server error, but the upload dropped the real error and had no part retry, and the Nanogram
  edec43752 rules made lost answers and empty uploads terminal.
- Where: `TelegramCore/Sources/PendingMessages/PendingSendFailurePolicy.swift` (classifier, budgets, retry operator, reason text),
  `State/PendingMessageManager.swift`, `Network/Download.swift`, `MultipartUpload.swift`, `MultiplexedRequestManager.swift`,
  `Network.swift`, `NetworkEngine.swift`, `PendingMessageUploadedContent.swift`; `MTProtoRustEngine` (`RustEngineMapping.swift`,
  `RustNetworkSession.swift`); `Postbox/Sources/Postbox.swift`; `MtProtoKit/MTRequestMessageService.m` (log line);
  `TelegramUI/Sources/ChatController.swift` (Retry menu).
- Upstream: partly (Postbox expiry and the upload/send catches are upstream code with Nanogram edits; the policy file is ours).
- Sync: keep the `pendingSendRetrying` wrap at the two `return sendMessageRequest` sites and the `retryingUpload` wraps at the two
  upload subscriptions; `PostboxImpl.init` gained `isMainProcess`. Mac port: shared core, the same code builds there; the Rust
  bridge change matters most on the Mac (Rust is its default engine).
- Not done: automatic resend of a message already marked failed, a Postbox-level `launch_expired` stamp, widening MtProtoKit's
  500-only retry to every 5xx/negative code (documented in the research, left for the logs to justify), BAD_MSG/REJECTED handling.
- Known limits (review): a text sent while an earlier message waits out a send backoff can reach the chat before it (the
  request dependency only orders requests in flight; before this change the earlier one failed instead). Uploads keep their
  order. A transient upload error restarts the whole file (new file id) up to 3 times, so a large video can cost up to three
  times its size on mobile data. Whether the server answers a repeated random id with the original message or with
  `RANDOM_ID_DUPLICATE` (500, which both engines retry without end) is not verified; the lost-answer resubmit relies on the
  former.

### Uploads: adaptive part window and first-answer limit (iOS and Mac, shared core, 2026-11-23)

- What: the number of upload parts in flight (`MultipartUploadManager.parallelParts`) is no longer fixed. `UploadPartWindow`
  (pure value type, `Network/UploadPartWindow.swift`) starts at the old 6 (parts under 512 KB) or 3 (512 KB parts) on Wi-Fi or an
  unknown network, lower on cellular (4 for 128 KB parts, 2 for bigger), grows by one for each clean fast part that started with
  the window full (Reno-style above the last decrease; not past what the measured goodput carries in 6 s), halves at most once
  per holdoff when a part is slow (over 8 s), retried, stalled or failed, and is capped at 8 parts and 1.5 MB. A flip to
  cellular lowers it; a part-size change or the big-file restart starts it over. History import (30) is untouched. A part with
  no answer after 8 s only shrinks the window. Phase 2 (`MultipartUploadManager.hardDeadlineEnabled`, own commit, OFF by
  default until tried on a device on a slow and an offline link): a part with no answer for 12 s + (bytes queued ahead + its
  size) / max(goodput, 12 KB/s) + 8 s is subscribed again once (same signal, same bytes) only when another part of the upload
  was answered meanwhile and the network is not "none"; the second expiry fails the upload only when nothing was answered in
  the whole period, else it waits with a doubled limit; never for history import or the non-multiplexed interface. One log line per upload (`upload end ok= parts= bytes= ms= part= win=min/max/final
  retries= stalls= fails= dec= net=a>b`) goes to the Send Report log. `pendingUploadPartRetrying` gained an optional `onRetry`.
- Why: owner sees red failed sends on cellular, almost never on Wi-Fi; a fixed window of 6 parts can hold more than a slow
  uplink answers in time, and nothing timed out a part that never got a first answer while other traffic kept the socket alive.
  Expect modest gains; the structural fix (a dedicated upload pool as in TDLib, tdesktop and Android) is not done.
- Where: `TelegramCore/Sources/Network/UploadPartWindow.swift`, `MultipartUpload.swift`,
  `PendingMessages/PendingSendFailurePolicy.swift`; tests `UploadPartWindowTests`, `MultipartUploadTests`.
- Upstream: no (Nanogram-only).
- Sync: keep `window` calls at part start, finish, failure and retry in `MultipartUploadManager`; the four `defaultPartSize`
  assignments go through `updatePartSize`. Mac: shared core, the Mac app picks this up through its core pin
  (`submodules/telegram-ios`), so bump the pin there (gitlink commit without a pathspec) and run the same tests.
- Not done: dedicated upload connection pool, resume of partial uploads, part-size adaptation, `networkDuration` samples.
- Not built; tests written, not run. The simulator scenarios use the worst case (any attempt of 12 s or more resets the connection).

### Hardware codec capability probe (iOS, 2026-11-14)

- What: `submodules/MediaCapabilities` (new, Nanogram-only) caches hardware decode and encode answers; `internal_isHardwareAv1Supported` delegates to it. `VideoDecodePolicy.usesPassthrough` / `usesHardwareAcceleration` keep AV1 off the passthrough and VideoToolbox hwaccel paths unless hardware AV1 exists (A17 Pro, M3 and newer), in `FFMpegFileReader` and `SoftwareVideoSource`. `DecodePathLog` logs codec and hardware or software once per launch. Send Logs adds a "Media capabilities" block.
- Why: the iOS 26 floor does not make AV1 hardware universal (A12 to A16 have none); the opens must be capability gated.
- Upstream: upstream has `internal_isHardwareAv1Supported` and the unconditional open paths; the edits there are small, in `MediaPlayer` only.
- Sync: re-apply the `VideoDecodePolicy` calls at the four open sites if upstream rewrites them. `MediaPlayer/Package.swift` (Mac) must list `MediaCapabilities`.

### Glanceables: chats widget, App Intents, Live Activities (iOS, Settings > Nanogram Features, default off)
- What: a second widget kind (`Nanogram_GlanceChats`, small and Lock Screen families, iOS 17+), App Intents with App Shortcuts and a Control Center button, and Live Activities for live location and for calls without CallKit. Names appear only while the app is unlocked and, on Lock Screen surfaces, only if "name on lock screen" allows it; counts always show.
- Where: `submodules/NanogramGlance` (pure model, policy, app-group store, intent bridge; host tests), `submodules/NanogramAppIntents`, `Telegram/WidgetKitWidget/{GlanceWidgets,GlanceControls,GlanceActivityWidget}.swift`, `submodules/TelegramUI/Sources/GlanceCoordinator.swift`, `Telegram/BUILD`.
- Upstream: no (upstream has no AppIntents or accessory families). Shared edits to keep in step on sync: `TodayViewController.swift` (`getCommonTimeline` split into `loadWidgetPeers`, `WidgetExtensionEnvironment` and `buildConfig` no longer private, three entries in `AllWidgets`), `ExperimentalUISettings` (`nanogramGlanceables`), `NanogramFeaturesController` (`.glanceables` row), `SharedAccountContext` (coordinator creation), `Telegram/BUILD` (deps, `app_intents`, `NSSupportsLiveActivities`).
- Sync: if upstream converts the widgets to AppIntents, drop our `SelectChatsIntent` in favour of theirs and keep `GlanceVisibility`.

### A/B report labels (iOS, 2026-11-14)
- What: the "Performance experiments" block in Send Logs labels each switch with its state at launch, not the stored value at send time.
- Why: a tester who flips the switch before sending logs would otherwise label run A as "on".
- Where: `ExperimentalPerformanceFlags.swift` (`launchState`, SwiftSignalKit and SwiftSignalKit2).
- Upstream: no.

## Enhance voice messages: Opus OSCE (LACE, NoLACE, BWE) for playback (iOS and Mac, shared core, 2026-11-15)
- What: opt-in Settings > Nanogram Features > "Enhance voice messages" (default off). When on, voice-message PLAYBACK opens the Opus decoder at complexity 7 (NoLACE; LACE at 6) with bandwidth extension. Transcription (`convertOpusToAAC`), the Notification Service extension, calls and the Watch app never use it. libopus carries the OSCE code and models for everyone (about +2.35 MB, +104 KB per decoder, about +5 us per SILK frame even with the switch off; see CHANGELOG.md).
- Where: `third-party/opus/BUILD` and `build-opus-bazel.sh` (options from `shared/opus/opus-options.sh`, models pinned in `MODULE.bazel` as `opus_models_tar_gz`, fetched by `shared/opus/fetch-models.sh --archive`); `submodules/FFMpegBinding` (`FFMpegAVCodecContext.setOpusDecoderComplexity:bandwidthExtension:`); `submodules/MediaPlayer/Sources/OpusSpeechEnhancement.swift` (switch mirror, option choice) with hooks in `FFMpegMediaFrameSourceContext.swift`, `FFMpegFileReader.swift`, `SoftwareVideoSource.swift` (`SoftwareAudioSource`, only when `isPlayback`); `NanogramFeaturesSettings.voiceEnhancement`, `NanogramFeaturesController.swift` (VOICE MESSAGES section), `SharedAccountContext.swift` (mirrors the setting into `OpusSpeechEnhancement.isEnabled`); fork klaipher/FFmpeg branch `osce` (`libopusdec.c`: `osce_complexity`, `osce_bwe`, flush re-creates the decoder when BWE is on because libopus keeps the BWE history across `OPUS_RESET_STATE`).
- Upstream: no (upstream has no such setting). The hooks sit in upstream files, so an upstream sync can drop them silently: after a sync check that the three playback hooks, the `FFMpegAVCodecContext` setter and its `AVDictionary` passing in `-open`, and the `SharedAccountContext` mirror are still there (`tools/dev/tests/test_opus_osce_guards.py` checks the wiring and the Watch guards).
- Sync: keep ours. The Watch app has its own vendored COpus without `dnn/` and must not change. A new libopus release needs the models hash bumped in `MODULE.bazel`, `opus-options.sh` and `shared-libraries.json` together (it lives in opus `autogen.sh`).

## Settings > Nanogram Features (iOS, 2026-11-14)
- What: a user-facing ItemList screen (Settings, after Power Saving) for Nanogram's own tweaks: in-chat search operators (`from:`, `before:`, `after:`, `date:`, `type:`; default on), a Voice messages section ("Enhance voice messages", default off, see the section above), link hygiene (strip tracking parameters when opening and copying a link, confirm t.me and tg:// links; both default off) and the user-facing switches moved out of Debug Settings (system noise suppression, advanced ducking, group noise suppression, thermal video limits, glanceables). Message text is never rewritten.
- Why: owner decision 2026-11-14 (Mercurygram feature parity, one screen per platform; developer experiments stay in Debug Settings).
- Where: `submodules/NanogramFeatures` (parser, link rules, tests), `submodules/TelegramUIPreferences/Sources/NanogramFeaturesSettings.swift`, `submodules/SettingsUI/Sources/NanogramFeaturesController.swift`, `submodules/TelegramUI/Sources/ChatSearchOperators.swift` and `ChatControllerUpdateSearch.swift`, `OpenUrl.swift` (`openExternalUrlImpl`), `TextLinkHandling.swift` (copy), PeerInfo settings list. Shared grammar and data: `docs/specs/search-operators.md`, `shared/data/link-tracking-params.txt` (nanogram-deps; the iOS copy under docs/specs is gone).
- Upstream: no. Ideas from Mercurygram (GPL-2.0), reimplemented from the behaviour, not copied. Attribution (Mercurygram Android commits): search operators 291b1c0ab, 61ed3f602, 94efecb78, 0884e7357 (MgSearchQuery); tracking-parameter strip and confirm t.me links 0ec92ad56, 38dbb8733, 197a708ae, 7c876bb07 (MgUrlCleaner and toggles).
- Sync: `updateSearch` and `openExternalUrlImpl` are small hooks; re-apply if upstream reshapes them. Copy hygiene covers the chat link menu only; the in-app browser and Instant View copy menus are not hooked.

## Mercurygram bug fixes and optimizations (iOS review, 2026-11-14)
- What: every bug-fix, security-fix and performance item of the Mercurygram analysis checked against Telegram-iOS code; table in `docs/nanogram/mercurygram-port.md`. Result: most Android items do not exist on iOS; Google DoH removal, proxy IPv6 resolving, the sound-reset and the livestream decoder guard are already in; one change, `RequestEditMessage` no longer overflows when an indefinite live location is extended.
- Secret-chat delete-for-everyone: fixed in the shared core (see the next entry); needs a test pair. Open: collapsed-community members versus type folders needs a device with communities.
- Attribution: Mercurygram Android a2d04746f (live location "until stopped"), analysis only; the fix is our own code.

## Secret chat: delete for everyone clears the peer's copy (iOS and Mac, shared core, 2026-11-14)
- What: deleting a secret chat for everyone (and ending it with history removal) now sends a clear-history service message first and turns the chat "terminated" only after `messages.discardEncryption` was requested. Before, the chat was marked terminated when the operation was queued, and a terminated chat sends no service messages, so the peer kept its history.
- Why: same bug as Mercurygram 01230d2c1 (Android), found in the iOS analysis.
- Where: `submodules/TelegramCore/Sources/TelegramEngine/Peers/RemovePeerChat.swift` (`secretChatTerminationPlan`, `queueSecretChatTermination`), `ManagedSecretChatOutgoingOperations.swift` (`requestTerminateSecretChat` sets the terminated state). Test: `SecretChatTerminationPlanTests`. The Mac app reaches it through `engine.peers.removePeerChat`, no Mac code.
- Upstream: no. Attribution: Mercurygram Android 01230d2c1 (GPL-2.0), behaviour only, our own implementation. Server relay issue bugs.telegram.org/c/27416.
- Sync: re-check if upstream touches the terminate operation or `addSecretChatOutgoingOperation`.

## On-device voice transcription and translation switches (iOS, 2026-11-14)
- What: Settings > Nanogram Features > ON-DEVICE has two switches, both OFF by default. On-device voice transcription (SpeechAnalyzer; it was on for every account since d6d49452/070ce28e): off means upstream behaviour (server transcription, Premium rules and trial). On-device translation: on makes message, poll and voice-transcription translation use Apple's Translation framework; the first use of a language pair shows the system download prompt; no result (model missing, prompt dismissed, unsupported pair) falls back to the server.
- Why: owner decision 2026-11-14 (spec diagnostics-and-debug-round2 section 10).
- Where: `NanogramFeaturesController.swift`, `NanogramFeaturesSettings.onDeviceTranslation`, `ExperimentalUISettings.localTranscription` (stored under the new key `nanogramOnDeviceTranscription`, so earlier default-on state does not carry over; the Debug Settings row is gone), `TranslateUI/ChatTranslation.swift` (`shouldTranslateOnDevice`), `TelegramCore/.../Translate.swift` (`translateTextsLocallyOrOnServer`).
- Upstream: upstream already translates on the device when the server config says `auto: system`; that rule stays when the switch is off.

## Send Report: one diagnostics button for testers
- What: Settings > Send Report (and the top of Debug Settings) sends one zip with a README, device and experiment details, app, extension and notification logs, critical logs, call logs, and crash and MetricKit reports, capped at 40 MB with phone numbers and emails masked; the old fine-grained Send Logs menu stays for developers.
- Why: testers had five or more log buttons and sent partial reports; upstream has no tester diagnostics flow.
- Energy and watch (2026-11-14): the report also holds `energy/energy.txt` (kernel counters of the app process, battery, Low Power Mode, thermal, per experiment since its switch changed) and `watch/` (the paired Apple Watch's report: its own manifest, info, energy numbers and log lines, requested over WatchConnectivity, else the last background copy). The watch has no button. Where: `submodules/EnergyNumbers`, `submodules/WatchReport`, `Telegram/WatchApp/Shared/{EnergyNumbers,WatchReportPayload}.swift` (one source for phone and watch), `Telegram/WatchApp/tgwatch Watch App/Diagnostics`, `submodules/DebugSettingsUI/Sources/{DebugEnergy,DebugReportSources}.swift`. Upstream: no. Sync: additive; the only upstream-file hook is one call in `SharedAccountContext.init`.


### Bisecting note
- Commits b1663a0b and d6d49452 reference `//submodules/MediaCapabilities` in `submodules/MediaPlayer/BUILD` and `submodules/DebugSettingsUI/BUILD` before the package exists (it arrives in e1c4b4e7), so those two commits do not build MediaPlayer or DebugSettingsUI. Skip them when bisecting.

## Review fixes: energy counters, watch reply size, link copy, from: lookups (iOS, 2026-11-14)
- What: the launch energy window starts from zero counters (`EnergyCounters.zero`) so every kernel counter is reported; the watch reply is cut to 60 KB; "Copy Link" in the chat link menu applies the tracking-parameter setting; `from:` lookups wait 0.6 s after the last keystroke and retry after 30 s; the energy report states that rates are per wall-clock minute.
- Where: `Telegram/WatchApp/Shared/{EnergyNumbers,WatchReportPayload}.swift`, `WatchReportSession.swift`, `ChatControllerOpenLinkContextMenu.swift`, `ChatSearchOperators.swift`.
- Upstream: no. Mercurygram attribution for search operators (291b1c0ab, 61ed3f602, 94efecb78, 0884e7357) and the URL cleaner (0ec92ad56, 38dbb8733, 197a708ae, 7c876bb07) is in `docs/nanogram/mercurygram-port.md`; code is our own.
- Sync: the chat link menu change is two one-line hooks.

## Server config reading fixes (iOS and Mac, shared core, 2026-11-14)

Patches to upstream bugs and one fix of our own code, found by the server-switches review.
- `SearchStickers.swift` (upstream bug): the key `"stickers_premium_by_emoji_num "` had a trailing space, so `SearchStickersConfiguration` always fell back to its defaults. Key fixed.
- `UrlHandling.swift` (upstream bug): `starref_start_param_prefixes` was read `as? String`, but the server sends an array. Now parsed by `StarRefStartParamPrefixes` (array, or a string for compatibility, default `_tgr_`).
- `ChatMessagePollBubbleContentNode.swift` (upstream inconsistency): fallback of `poll_answers_max` 20 -> 10, same as the poll composer.
- Our `CallRingTimeout` (4ff25ba7) read `call_ring_timeout_ms` from the app config; it is a `help.getConfig` field, now stored from `managedConfigurationUpdates`.

## Review fixes: on-device switches and secret-chat delete (iOS and Mac, shared core, 2026-11-14)

- Secret-chat termination: `queueSecretChatTermination` looks for a queued `.terminate` in the SecretOutgoing log first. If there is one, a second request only folds `reportSpam` into it, so Block + Delete (`terminateSecretChat` then `removePeerChat`) keeps the chat established until the flush `clearHistory` has been sent. Incoming secret messages are dropped while a terminate is queued (`secretChatTerminationQueued` in both incoming stages).
- Translation: `translateMessages(..., localOnly:)` is set from the user's switch only (not from the server's system-translator hint). With it, messages, polls and voice transcriptions fail instead of reaching the server; rich messages are left untranslated.
- Transcription: no server retry while the on-device switch is on.
- Check in the build: translate a chat with polls and voice transcriptions while the download sheet is open (several Translation tasks start together; look for "Translation error" in the logs and for translateText requests, which must not appear with the switch on). If the batches cancel each other, queue the tasks per language pair.

## Store builds sell no Telegram purchases (iOS and Mac, shared core, 2026-11-14)

- `StorePurchasePolicy` (InAppPurchaseManager module) is the single switch: Premium, Stars top-ups, Premium gifts and giveaways, paid boosts and every StoreKit request are off in store builds (App Review 3.1.1). Everything the account already owns keeps working: Premium features, owned Stars, receiving and converting gifts, gift codes, physical-goods bot payments.
- `PremiumConfiguration` has two flags. `isPremiumDisabled` (server `premium_purchase_blocked` OR store policy) gates purchase and upsell entry points only. `isPremiumDisplayDisabled` (server value only, as upstream) gates everything that shows Premium status or lets a Premium account use what it has: badges, emoji statuses, Premium app icons, Premium stickers, emoji-pack tips. Store builds therefore still show other users' Premium badges. Non-Premium accounts in store builds still do not see locked Premium stickers or Premium app icons (they would lead to an upsell).
- Defining `NANOGRAM_PURCHASES_ENABLED` turns purchases back on for a non-store build.
- Check in the build: another user's Premium star shows in the chat list and the chat title; Settings > Premium shows the feature list with no subscribe button; opening a Stars top-up link shows the "can't be bought" alert; the gift sheet has no Premium options; Send Report info says `Store build: yes`; the log shows no `SKProductsRequest` at launch.

### Navigation: stalled screen changes recover, and are logged (iOS, 2026-11-21)
- What: a chat still not ready 5 s after it was pushed is shown as it is, and a tap push or pop still animating after 3 s is
  landed at its end (a finger-held swipe is never touched); each recovery is logged as `[Navigation] recovery:`. The
  navigation container also logs every stack change, the screen a push waits for, each transition's start and end, a
  `stall:` line naming the chat's missing readiness inputs, flat/split switches and, at launch, the Debug switches that
  differ from their defaults. Debug ▸ "Reset Debug Settings" puts every Debug switch back to its default and keeps the
  Nanogram Features fields stored with them (`ExperimentalUISettings.resettingDebugSwitches`). A screen shown before it was
  ready does not delay a tap back to it.
- Why: on one tester's iPhone 14 Pro (iOS 27.2.1) chats tapped in the chat list never appeared and back did nothing until
  the app was reinstalled; upstream waits for a pushed screen's `ready` and for a transition's landing with no timeout,
  so one input that never arrives freezes the stack silently. The cause was not found.
- Where: `submodules/Display/Source/Navigation/NavigationDiagnostics.swift` (`NavigationDiagnostics`, `NavigationRecovery`),
  `NavigationContainer.swift`, `NavigationController.swift`, `ViewController.navigationReadinessReport` /
  `showsWhenReadyStalls` (the chat opts in), `ChatControllerContentData.swift` and `ChatControllerLoadDisplayNode.swift`
  (readiness recorders), `DebugController.swift` (`resetDebugSettings`).
- Upstream: no.
- Sync: `NavigationContainer.swift` is fork-heavy already; keep the pending-child and transition-start hooks when merging.


### Tester log report fixes (iOS and Mac where shared core, 2026-11-26)
- What (differs from upstream):
  - MtProtoKit: `MTRequestMessageService.alwaysInitializeApi`; the backup-address getConfig is always wrapped in invokeWithLayer + initConnection (upstream sends it bare once the key remembers the environment, and the base-layer answer fails to parse).
  - TelegramCore Logger: early file lines are held until the stored Log to File setting is applied (upstream writes from launch with logToFile = true); push tokens are logged as a short prefix only. Short log: `ShortLogFilter` keeps routine MTProto/Postbox lines out of the critlog and counts them.
  - TelegramCore: `updateLocallyDerivedData`/`storeLocallyDerivedData` skip unchanged data; the gallery stores the video position at most every 5 s (upstream 0.5 s).
  - TelegramCore: read-state sync retries back off 1 s -> 30 s per chat (upstream retries at once).
  - TelegramCore: forced refreshes of a consistent cached sticker pack send its hash to `messages.getStickerSet` (upstream always 0).
  - TelegramCore: a `.sync` request queues one sync entry for recent stickers, faved stickers and saved GIFs (upstream queues two).
  - Chat open: the viewDidAppear full-peer refresh is skipped while the peer view's fetch started under 5 s ago is running or succeeded (`AccountViewTracker.refreshCachedPeerDataOnChatOpen`; upstream always forces it).
  - AppDelegate: the nightly cleanup task writes `TelegramCacheIndexTimestamp_v2` (upstream only the launch check does).
  - AccountManager: access-challenge open errors are logged with their error; wording depends on whether a migration can happen.
  - EntityKeyboard: emoji/sticker keyboard data is built on its own serial queue (upstream builds it on whatever thread delivered last, often inside a Postbox transaction).
  - TelegramAudio: audio ports are logged by type and uid tag, never by name; the route line only on change.
  - TelegramCore: our own unchanged typing activity is re-sent after 4.5 s (upstream 1 s).
  - TelegramCore: greeting/premium/all-premium `messages.getStickers` lists send the server's stored hash (item-cache collection 30; upstream 0).
  - Postbox: `StoryGeneralStatesTable.set` skips identical bytes like `PreferencesTable.set` (upstream rewrites every time).
  - Background tasks (fork code): drain until 2 s before expiration, expiration ends a drain, no write window without a granted task.
  - tgcalls (fork): video start bitrate floor when outgoing video turns on; call logs redact addresses, ICE passwords and fingerprints.
- Why: tester report 2026-11-25 (0xdead10cc, log volume, redundant requests and writes, privacy of logs).
- Where: CHANGELOG.md Unreleased entry "Tester log report 2026-11-25" lists every file and commit.
- Upstream: candidates for PRs (sticker sync double entry, chat-open double fetch, backup getConfig, derived-data no-op writes).
- Sync: expect conflicts in AccountViewTracker.swift, ChatController.swift (~8209), TelegramEngineMessages.swift, UniversalVideoGalleryItem.swift, CachedStickerPack.swift/LoadedStickerPack.swift, Synchronize*Operation(s).swift, ManagedSynchronizePeerReadStates.swift, MTRequestMessageService.m, Log.swift, EmojiPagerContentSignals.swift, ManagedAudioSession.swift, PeerInputActivityManager.swift, ManagedRecentStickers.swift, StoryStatesTable.swift.
