# Runtime efficiency: specs from the 2026-10-30 code audit

A read-only review of the code (no profiling) for features that waste battery, CPU, memory or data at
runtime. Each spec below is one change to make later. Line numbers are as of upstream release 13.1.1 plus
this fork's changes on 2026-10-30; re-check them before starting.

- **Verified**: the claim was checked by reading the code, not only reported by the review.
- **Size**: S = a few lines, M = one file or a few call sites, L = a design change across modules.
- Every fix touches Telegram's own code, so it can conflict on an upstream sync. Prefer small, local changes.
- Verification for every spec: the full `tools/dev/tg build`, a run in the iOS 27.2 simulator, and, where
  the spec says so, a measurement before and after (Instruments: Time Profiler, Energy Log, Allocations,
  Network; or the counters named in the spec).

Status values: `todo`, `in progress`, `done (<commit>)`, `dropped (<reason>)`.

## Quick fixes (S)

### R1. Polls with a deadline are re-fetched every 0.5 s — `done (9bc6231a)`, verified

- **Where**: `submodules/TelegramCore/Sources/State/AccountViewTracker.swift:549-583`.
- **Problem**: `remainingTime = timestamp - startDate - 1` is the time since the poll was posted, not the
  time left until its deadline (`deadlineTimeout` is checked for presence and never used). After that delay
  the signal switches to `fetchPoll` → 0.5 s delay → `restart`, which never stops while the message is
  visible. Before the "deadline" it refreshes every 30 s.
- **Fix**: `remaining = startDate + deadlineTimeout - now` (server time: use the account's time difference);
  after the deadline, fetch until the poll reports closed, then stop or fall back to the 30 s refresh.
- **Check**: open a chat with a deadline poll; count `messages.getPollResults` requests per minute
  (network telemetry in a debug build, or a breakpoint in `fetchPoll`).

### R2. Automatic power saving stops working after the first call — `done (9bc6231a)`, verified

- **Where**: `submodules/TelegramCallsUI/Sources/PresentationCall.swift:1181,1194,1255,1268`;
  `submodules/TelegramPresentationData/Sources/PresentationData.swift:531-545`.
- **Problem**: the call sets `UIDevice.current.isBatteryMonitoringEnabled = false` when its battery signal is
  disposed. The app turned it on at launch (`AppDelegate.swift:460`), so afterwards `batteryLevel` is -1 and
  `automaticEnergyUsageShouldBeOnNow` always returns false: the "power saving below N %" setting never kicks
  in again until relaunch.
- **Fix**: don't turn monitoring off in `PresentationCall` (the app keeps it on), or reference-count it.
- **Check**: make a call, end it, then read `UIDevice.current.batteryLevel` (≠ -1).

### R3. Live location keeps the compass running and sends updates while standing still — `todo`, compass verified

- **Where**: `submodules/DeviceLocationManager/Sources/DeviceLocationManager.swift:56-62,117-127`;
  `submodules/LiveLocationManager/Sources/LiveLocationManager.swift:123-126,228-248`.
- **Problem**: `startUpdatingHeading()` is never matched by `stopUpdatingHeading()`, and the manager is
  shared, so the compass stays on after sharing ends. Accuracy is 10 m with no `distanceFilter`,
  `pausesLocationUpdatesAutomatically = false`, and one `editMessageLiveLocation` per shared chat every 4 s
  even without movement.
- **Fix**: stop heading updates together with location; in the background use ~100 m accuracy, a 25–50 m
  distance filter and auto-pause; skip edits when position/heading barely changed; back off to 30–60 s
  when stationary.
- **Check**: share live location for 15 min stationary; compare edit requests and Energy Log.

### R4. Group-call logging always on, and an unbounded in-memory log during screen sharing — `todo`, verified

- **Where**: `submodules/TgVoipWebrtc/Sources/OngoingCallThreadLocalContext.mm:2680` (`need_log = true`);
  `tgcalls/group/GroupInstanceCustomImpl.cpp:3773-3780` (`SetLogToStderr(true)`, `LS_INFO`);
  `TelegramCallsUI/Sources/GroupCallScreencast.swift:91` (empty log path) →
  `tgcalls/LogSinkImpl.cpp:55` (`ostringstream` that is never drained).
- **Fix**: no stderr logging in release; with an empty path, don't install the sink.
- **Check**: memory of the broadcast extension over a 30 min screen share.

### R5. The cheaper custom-emoji renderer is behind a debug switch — `in progress` (timer tolerance, 3cd4aadf; moving it to the shared display link measured worse), verified

- **Where**: `submodules/TelegramUIPreferences/Sources/ExperimentalUISettings.swift:112`
  (`compressedEmojiCache: false`); `DCTMultiAnimationRendererImpl.swift:909-930`,
  `DCTAnimationCacheImpl.swift:603,729-730`.
- **Problem**: emoji frames are rendered with a 60 Hz `Foundation.Timer`, new buffers per frame (reuse
  disabled by `!"".isEmpty`) and a CPU YUV→ARGB conversion. A GPU-side YUVA path exists but is off.
- **Fix**: enable the compressed path by default (after checking why it is still experimental), then pool
  buffers and drive the renderer from the shared display link.
- **Check**: Time Profiler on a chat full of animated custom emoji, before/after.

### R6. Auto night mode polls every second — `done (9bc6231a)`, verified

- **Where**: `submodules/TelegramPresentationData/Sources/PresentationData.swift:505-520`.
- **Problem**: a 1 s repeating main-queue timer for every trigger except `.explicitNone`, including the
  default `.system`, which changes only with the system appearance.
- **Fix**: no timer for `.system`; for the time trigger, a single timer to the next switch; for brightness,
  `UIScreen.brightnessDidChangeNotification`.

### R7. Low Power Mode and thermal state are ignored — `todo`

- **Where**: `PresentationData.swift:531-565` (battery percentage only); `AppDelegate.swift:2077`;
  `DCTMultiAnimationRendererImpl.swift:930` (read once at init).
- **Fix**: treat `ProcessInfo.isLowPowerModeEnabled` or thermal state `.serious`/`.critical` as "power saving
  on", observing `NSProcessInfoPowerStateDidChange` and `thermalStateDidChangeNotification`.

### R8. Display links and sensors that keep running — `in progress` (1 Hz autoremove/timestamp loops → 10 s and the AppLock 5 s write only with a passcode: 9bc6231a)

- Media editor: a 60 fps `CADisplayLink` stays active while a video is paused
  (`TelegramUI/Components/MediaEditor/Sources/UniversalTextureSource.swift:96-117`). Pause it when `rate == 0`.
- Mini Apps: page-supplied sensor `refresh_rate` is not clamped and sensors keep running while minimized;
  device motion is not stopped in `deinit` (`WebUI/Sources/WebAppController.swift:465-479,1773,2810,2851,2922,4168-4182`).
  Clamp to ≥ 20 ms, pause while minimized, stop all three in `deinit`.
- Group-call Metal renderer: the 60 Hz link never pauses and `VideoRenderingContext.updateVisibility` has no
  callers (`TelegramCallsUI/Sources/MetalVideoRenderingView.swift:604-617`, `VideoRenderingContext.swift:63`).
  Call it on present/minimize and skip ticks with nothing to redraw.
- Always-on 1 Hz timers per account (`ManagedAutoremoveMessageOperations.swift:49-56,145-152`,
  `ManagedPeerTimestampAttributeOperations.swift:51-60`) and the 5 s lock-state write without a passcode
  (`AppLock.swift:278,338,375-377`): schedule to the next due time instead.

### R9. SQLite WAL is never checkpointed or size-limited — `todo`

- **Where**: `submodules/Postbox/Sources/SqliteValueBox.swift:609-610,627,687`.
- `checkpoint()` has no callers; `wal_autocheckpoint`/`journal_size_limit` are commented out;
  `checkpoint_fullfsync=1`. The app and the notification extension share the WAL, so read the self-heal
  notes in `CLAUDE.md` (SQLCipher section) before changing anything.
- **Fix**: set `journal_size_limit`, run a PASSIVE checkpoint when entering the background.

## Medium changes (M)

### R10. Livestream video in group calls is decoded in software — `todo`, verified

- **Where**: `tgcalls/tgcalls/platform/darwin/DarwinFFMpeg.mm:21-31` (`setupDarwinVideoDecoding` returns
  immediately; the VideoToolbox code is commented out), called from `group/VideoStreamingPart.cpp:345`; each
  frame is then copied into an `I420Buffer` (`:619`).
- Telegram may have disabled it on purpose: find out why (git history of tgcalls, crashes on specific
  devices) before turning it back on, and keep the software path as a fallback.
- **Check**: CPU during a 1080p livestream on a device.

### R11. Animated stickers render on the CPU with one timer each — `todo`

- **Where**: `AnimatedStickerNode/Sources/AnimatedStickerNode.swift:314-317,423,582`,
  `AnimatedStickerFrameSource.swift:542-544,613-623`, `SoftwareAnimationRenderer.swift:49-60,182`.
- No caller passes `useMetalCache: true`, so every sticker uses `SoftwareAnimationRenderer`: per-frame file
  read, LZFSE decompression, CPU YUVA→RGBA into a new `UIImage`, two main-thread hops, and its own dispatch
  timer at the sticker's native fps. 67 call sites use `.direct(cachePathPrefix: nil)`, re-running rlottie on
  every loop.
- **Fix**: route playback through the compressed/Metal renderer or the shared emoji renderer, cap fps, and
  give the uncached call sites a cache path.

### R12. Stickers and emoji keep animating in the background — `todo`

- The shared display link stops in the background (`Display/Source/DisplayLinkAnimator.swift:103-116`), but
  sticker timers and the emoji timer are gated only on visibility (`AnimatedStickerNode.swift:423`,
  `EmojiTextAttachmentView.swift:637`); `ChatController.swift:6976-6990` does not stop them. Matters while the
  app stays alive in the background (music, voice messages).
- **Fix**: also gate on application state.

### R13. `LottieComponent` renders on the main thread every frame — `todo`

- `TelegramUI/Components/LottieComponent/Sources/LottieComponent.swift:441-451`: a new drawing context per
  frame on main; 110 call sites, 15 looping. Render off-main or cache frames.

### R14. Display link frame rate — `in progress` (shared link asks for 60/30 Hz: 3cd4aadf)

- `DisplayLinkAnimator.swift:168-185,219-229`: on iPad the shared link asks for 120 Hz whenever any link is
  active; 30 fps links are throttled in software, so main still wakes at 60+ Hz. Pass the highest requested
  rate as `preferredFrameRateRange`.
- CoreList scroll flights pin min = max = 120 Hz and `pinsSamplingLinkRate = true`, which its own comment
  says doubles main-thread row work (`CoreList/CoreListDemo/PhysicsScrollEngine.swift:722,745-749`). Try
  `pinsSamplingLinkRate = false` and drop the pin in Low Power Mode; measure scroll smoothness.

### R15. Profile data preloaded on every chat open — `todo`

- `TelegramUI/Sources/ChatController.swift:8057-8067` starts `keepPeerInfoScreenDataHot` for the whole
  controller lifetime: 7 tagged history views of 20 items with `clipHoles: false` (server fetches to fill
  holes), profile photos and two story lists (`PeerInfoScreen/Sources/PeerInfoData.swift:613-646,738-760`).
- **Fix**: start it on intent (header tap or a dwell time), or use search counters instead of 7 views.

### R16. Auto-download ignores Low Data Mode and expensive networks — `todo`

- No `isConstrained`/`isExpensive` anywhere; `NetworkType.swift` uses reachability only, so Personal Hotspot
  counts as Wi‑Fi and gets the high preset (`MediaAutoDownloadSettings.swift:393-399`,
  `PrefetchManager.swift:44-50`).
- **Fix**: `NWPathMonitor`; treat constrained/expensive paths (and Low Power Mode) as cellular or the low preset.

### R17. Chat photos decoded at full size, no decoded-image cache — `todo`

- `PhotoResources/Sources/PhotoResources.swift:893-895`: decode with a maximum pixel size
  (`CGImageSourceCreateThumbnailAtIndex`) and add a small memory-pressure-aware cache.

### R18. RNNoise runs even when noise suppression is off — `todo`

- `tgcalls/group/GroupAudioCapturePostProcessor.cpp:78-99`: `rnnoise_process_frame` runs every 10 ms for
  voice-activity detection even when suppression is off, and a new `webrtc::AudioBuffer` is allocated per
  frame on size mismatch. Note rnnoise 0.2 (this fork) is a bigger model, which makes this more expensive.
- **Fix**: cheaper VAD when suppression is off; reuse the buffer.

### R19. Background radio wake-ups — `todo`

- Online presence: `account.updateStatus` every 30 s while in the foreground
  (`TelegramCore/Sources/State/ManagedAccountPresence.swift:48-57`).
- Promo channel polled permanently, for every account (`ManagedProxyInfoUpdates.swift:279`,
  `AccountTaskManager.swift:189`).
- MtProtoKit reconnect retries 1 s → 4 s → 8 s forever, no jitter, no reachability check
  (`MtProtoKit/Sources/MTTcpConnectionBehaviour.m:57-76`, `MTTcpTransport.m:569-580`).
- Rust engine (opt-in on iOS): RTT estimate floor of 2 s drives pings (`mtproto-core/src/session/mod.rs:1310-1333`).

## Design changes (L)

### R20. Chat history re-lays out every loaded row on every update, on the main thread — `todo`

- `TelegramUI/Sources/ChatHistoryListNode.swift:2056,2648` (`messageViewQueue = mainQueue`,
  `allUpdated: !isSavedMusic || forceUpdateAll`); `CoreListChatHistoryBackend.swift:953-955,1784,2020,2097`
  (new `stableVersion` per update, synchronous `updateNode`). A read receipt or reaction rebuilds ~88 entries
  and re-measures every bubble in the window; the legacy ListView did this layout off main.
- **Fix**: `allUpdated` only on presentation/associated-data changes; layout off the main thread.
- **Check**: Time Profiler of main thread while receiving reactions in an open busy group.

### R21. Postbox recomputes every live view on every transaction — `todo`

- `Postbox/Sources/ViewTracker.swift:278-420`; up to 30 preload views of 50 messages
  (`ChatListUI/Sources/Node/ChatListNode.swift:3397`, `TelegramCore/Sources/State/ChatHistoryPreloadManager.swift:439`);
  3 chat list views alive (`ChatListControllerNode.swift:1072-1088`); screens lower in the navigation stack
  keep theirs; any peer update scans all entries (`MessageHistoryViewState.swift:1663`).
- **Fix**: pause views of invisible screens; lower the preload count.

### R22. Unbounded caches, no memory-warning handling — `in progress` (memory-warning handler, throttle-record pruning: 9bc6231a)

- No Swift handler for `didReceiveMemoryWarningNotification`; Postbox caches (`PeerTable.cachedPeers`,
  cached peer data, presences, read states) and `PresentationsResourceCache` are unbounded and cleared only
  on background/account change (`TelegramUI/Sources/AppDelegate.swift:2090`).
- **Fix**: call `postbox.clearCaches()` (and image caches) on memory warnings; add LRU limits.

### R23. Gradient wallpaper regeneration — `todo` (low priority)

- `GradientBackground/Sources/SoftwareGradientBackground.swift:574-601` regenerates 15–60 frames per message
  animation; `WallpaperBackgroundNode.swift:486-528,548` redoes a full-screen blend on main behind a
  one-entry cache; loops while a chat loads (`ChatLoadingNode.swift:235`).

## Found and fixed while measuring (2026-10-30)

- Streamed video left a temp copy of every segment until relaunch (242 MB in a 3-minute browse); segments
  crossed the JS player as base64 both ways (7ddeada8).
- Retain cycles: poll/todo option nodes, context-menu custom items, reposted-story captions, Gifts pane
  subscription, live-stream frame map, UniversalVideoManager bags (42e24c27).
- Unchanged peers and view counts rewritten on every update; StorageBox no-op writes; 0xdead10cc from
  databases still writing when a background task expired (f997e5c0).
- 2 Hz memory logger, 10 Hz read-metrics heartbeat, hidden chats' 10 s refresh, widget/folder polls (9bc6231a).

Measured with the same AXe-driven scenario (60 s idle chat list, 10 busy channels opened and scrolled, 30 s
idle), debug builds, back to back: browsing CPU 74.8 → 60.4 s, written 348 → 273 MB, peak memory 306 → 243 MB,
temp files left 242 → 0 MB. Idle readings vary more between runs than between builds on a live account.

## Already done well (keep)

- Only the active account keeps its connection in the foreground; background time is capped at 30 s and
  released early; Low Power Mode disables the background extension (`SharedWakeupManager.swift`,
  `AppDelegate.swift:2077-2084`).
- One shared `CADisplayLink` that stops when idle or in the background; per-link fps throttling.
- Shared emoji animations with one frame in memory; compressed on-disk frame caches; visibility gating.
- Video playback through `AVSampleBufferDisplayLayer` with hardware decoding; hardware H.264 encoder for calls;
  incoming group-call video suspended when not shown.
- Logging off in App Store builds; network telemetry off unless enabled by the server and cheap when on.
- Legacy ListView lays out off the main thread; chat list diffs on a background queue; text layout reuse.
