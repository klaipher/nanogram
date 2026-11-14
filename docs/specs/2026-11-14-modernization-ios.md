# iOS specs (app and shared iOS core)

Repo: `klaipher/nanogram` (local `~/Projects/nanogram-ios`). Base for all new branches: the `build/modernize` tip (a3ef6e0f, which already contains `round/2026-11-13`, `perf/*` and `core/drop-rlottie`). iOS `main` (f059025a) is behind it; the stack merges into `main` before the shared-core changes go to the Mac.

**Shared core** = a module listed in `nanogram-macos/docs/mac-core-paths.txt` (MtProtoKit, MediaPlayer, SSignalKit, GraphCore, TelegramAudio, Postbox, TelegramCore, ...). These land in iOS `main`, then on the Mac with `tg core-bump`. Note: several findings were tagged `sharedCode: true` although their module is iOS-only (PhotoResources, AnimatedStickerNode, AnimationCompression, BatchVideoRendering, MediaEditor, DeviceLocationManager, LegacyComponents, DeviceAccess, GalleryUI). The scope line below uses the paths file, not the tag.

---

### IOS-CRYPTO-1: AES-IGE decrypt makes one CommonCrypto call per 16-byte block
- **Severity:** medium
- **Scope:** shared core (MtProtoKit). iOS main, then Mac via core-bump.
- **Evidence:** `submodules/MtProtoKit/Sources/MTAes.m:146-200`, `MyAesIgeDecrypt` calls `CCCryptorUpdate` in ECB mode per block with a status check each time. Encrypt already uses the bulk CBC trick. All `MTEncryption.m` decrypt paths (269, 301, 315, 328, 374) use it, so it is the default inbound path for MTProto 2.0 messages and file chunks. About 65k calls per 1 MB.
- **Change:** a fused decrypt loop with ARMv8 AES intrinsics (`vaesdq_u8`, `vaesimcq_u8`, expanded decrypt key, guarded by `__ARM_FEATURE_AES`), keeping a CommonCrypto fallback for other targets. Keep zero output on failure. Do not add BoringSSL as a dependency (it is not linked into MtProtoKit; see cross-platform XP-13). Keep the old loop as a test-only reference.
- **Docs:** https://developer.arm.com/architectures/instruction-sets/intrinsics/vaesdq_u8 (ARMv8 Crypto Extensions, every arm64 iPhone and Apple Silicon Mac).
- **Risk:** low to medium. Crypto: needs byte-identical output on random vectors, including iv in/out chaining and unaligned buffers, on iOS and Mac.
- **Measurement:** micro-benchmark on 128 KB, 512 KB and 1 MB buffers; Time Profiler on the MTProto queue during a 200 MB download.
- **Effort:** small
- **Status:** open

### IOS-SPEECH-1: Voice transcription leaks a temp copy and uses legacy SFSpeechRecognizer (merged duplicate)
- **Severity:** low (the only caller is gated by the experimental `localTranscription` flag, off by default)
- **Scope:** iOS only (`submodules/Media/LocalAudioTranscription`).
- **Evidence:** `LocalAudioTranscription.swift:55-58` copies the file into `NSTemporaryDirectory()` and never removes it. Line ~112 divides confidence by `segments.count`, giving NaN for an empty result that breaks the sort at ~133. No SpeechAnalyzer on iOS; the Mac already has the chain (`docs/feature-parity.md:42/122`).
- **Change:** step 1: remove the temp copy on finish, error and dispose (or read the original path), and guard the empty-segment division. Step 2: on iOS 26+ use `SpeechTranscriber` with `SpeechAnalyzer.analyzeSequence(from:)` and `AssetInventory` model download, checking `SpeechTranscriber.supportedLocale`; keep SFSpeechRecognizer on-device as the fallback. Port the Mac design so both apps share one shape. Stays behind the existing experimental flag.
- **Docs:** https://developer.apple.com/documentation/speech/speechanalyzer ; WWDC25 277.
- **Risk:** low for step 1; medium for step 2 (transcript text changes, model download).
- **Measurement:** tmp file count after 20 transcriptions stays 0; WER and latency on 20 notes in two languages.
- **Effort:** small (step 1) + medium (step 2)
- **Status:** step 1 done (no temp copy, NaN guard; branch mod/ios-platform); step 2 done behind `-NanogramSpeechAnalyzer YES` (default off), awaiting device check

### IOS-SIMD-1: Multi-threaded software AV1 decode is Mac-only
- **Severity:** low (owner deferred it pending measurement)
- **Scope:** shared core (MediaPlayer).
- **Evidence:** `FFMpegSoftwareDecodeThreads.swift:16` applies thread counts under `#if os(macOS)` only. Callers: `UniversalSoftwareVideoSource.swift:224-229`, `FFMpegMediaFrameSourceContext.swift:491`, and `FFMpegFileReader.swift:407` (HLS chunk player, the most important one). Software AV1 is on when `hw.ncpu >= 6` (`ios_enable_software_av1`). No AV1 hardware before A17 Pro and M3.
- **Change:** enable the iOS branch behind a flag that defaults off. Cap iOS threads at min(activeProcessorCount, 4); 1 thread in Low Power Mode or at thermal state `.serious` or above. Flip the default only after an A/B on an A15 or A16 device.
- **Docs:** dav1d threading https://code.videolan.org/videolan/dav1d ; FFmpeg libdav1d `threads` option.
- **Risk:** low.
- **Measurement:** `takeFrame(at: 0)` plus 10 scrub steps and HLS playback of a 1080p AV1 clip, threads 1 vs 4, CPU and Power Profiler.
- **Effort:** small
- **Status:** open

### IOS-VIDEO-1: Scrub previews decode H.264/HEVC in software
- **Severity:** low
- **Scope:** shared core (MediaPlayer) and iOS-only callers in TelegramUI.
- **Evidence:** `UniversalSoftwareVideoSource.swift:224` uses `preferHardwareAccelerationCapable: false` and never calls `setupHardwareAccelerationIfPossible()`. Callers: MediaPlayerFramePreview (`UniversalVideoGalleryItem.swift:1451`) and the first-frame representations (`FetchCachedRepresentations.swift:46/74`).
- **Change:** opt-in hardware decode for the gallery scrub-preview session only (not for single-keyframe first-frame caching), H.264 and HEVC, with software fallback on failure, and no VT session while a main player holds one. Behind a flag until measured.
- **Docs:** https://developer.apple.com/documentation/videotoolbox
- **Risk:** medium (VT session limits, different pixel format).
- **Measurement:** CPU and Power Profiler while scrubbing a 4K HEVC clip for 20 s; time to first preview frame.
- **Effort:** medium
- **Status:** open

### IOS-CI-1: New CIContext on every sticker cutout, outline and generation
- **Severity:** low
- **Scope:** iOS only (MediaEditor).
- **Evidence:** `ImageObjectSeparation.swift:130` and `:246`, `MediaEditorStickerGeneration.swift:21`, `StickerCutoutOutlineView.swift:303`. Other MediaEditor passes already keep one context.
- **Change:** one shared media-editor CIContext (Metal device from MetalEngine), with each site's current colour-space options preserved; drop on memory warning.
- **Docs:** https://developer.apple.com/documentation/coreimage/cicontext
- **Risk:** low.
- **Measurement:** signpost first and repeated cutout; peak memory in Metal System Trace.
- **Effort:** small
- **Status:** open

### IOS-IO-1: Chat photo loaders read whole files into heap Data
- **Severity:** low
- **Scope:** iOS only (PhotoResources).
- **Evidence:** 31 `Data(contentsOf:..., options: [])` reads in `PhotoResources.swift` (161, 164, ...), all behind `.complete` checks, feeding `CGImageSourceCreateWithData`. The same file already uses `.mappedIfSafe` in about 8 places.
- **Change:** `.mappedIfSafe` for `.complete`-guarded reads only (or `CGImageSourceCreateWithURL` in thumbnail paths). Leave partial-file reads unmapped.
- **Docs:** https://developer.apple.com/documentation/foundation/nsdata/readingoptions/mappedifsafe
- **Risk:** low.
- **Measurement:** peak dirty memory and decode-queue time opening a 100-photo chat and fast scrolling.
- **Effort:** small
- **Status:** open

### IOS-WIDGET-1: Widgets use legacy IntentConfiguration, medium size only
- **Severity:** medium
- **Scope:** iOS app (widget extension, `Telegram/BUILD`).
- **Evidence:** `Telegram/WidgetKitWidget/TodayViewController.swift` IntentTimelineProvider at 260/284, IntentConfiguration at 936/953, `.supportedFamilies([.systemMedium])` at 939/956. No AppIntent, AppEntity or accessory family anywhere.
- **Change:** iOS 17+: `AppIntentConfiguration` + `AppIntentTimelineProvider` with a `PeerEntity` (EntityQuery over the existing widget peer JSON in the app group) and a migration from the old intent so placed widgets keep their selection. Keep IntentConfiguration widgets for iOS 15-16 via `if #available` in the WidgetBundle. Add `systemSmall` and accessory families (iOS 16+). Lock Screen shows counts only while locked. Reuse the throttled WidgetDataContext reloads.
- **Docs:** https://developer.apple.com/documentation/widgetkit/appintentconfiguration ; https://developer.apple.com/documentation/appintents/converting-sirikit-intents-to-app-intents
- **Risk:** medium (configuration migration; 30 MB extension limit).
- **Measurement:** extension memory; reload count per day; manual Lock Screen, StandBy and Home Screen checks.
- **Effort:** large
- **Status:** open

### IOS-LIVEACT-1: No Live Activity for live location or calls
- **Severity:** low
- **Scope:** iOS app. Depends on IOS-WIDGET-1 (same extension).
- **Evidence:** no ActivityKit or `NSSupportsLiveActivities`. `DeviceLocationManager.swift:82` `showsBackgroundLocationIndicator` is the only background UI.
- **Change:** ActivityAttributes and a Live Activity in the existing widget extension; set `NSSupportsLiveActivities`. Start and end it from an app-layer coordinator that observes the live-location and call state (do not edit DeviceLocationManager, which IOS-LOC-1 owns). Generic title when locked or when `displayNameOnLockscreen` is off. Set a `staleDate`. Interactive Stop on iOS 17.
- **Docs:** https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- **Risk:** low to medium (Lock Screen privacy; stale activity after a kill).
- **Measurement:** manual: start sharing, lock, Stop ends sharing; kill app, activity goes stale.
- **Effort:** medium
- **Status:** open

### IOS-APPINTENTS-1: No App Intents, App Shortcuts or Control Center controls
- **Severity:** medium
- **Scope:** iOS app.
- **Evidence:** `Telegram/SiriIntents/IntentHandler.swift:186` INExtension only; no AppIntent, AppShortcutsProvider, ControlWidget or AppEntity. Spotlight indexes contacts only.
- **Change:** in-app App Intents (no new extension target, so no new provisioning): `OpenChatIntent` with `PeerEntity` (shared with IOS-WIDGET-1), `SendToSavedMessagesIntent` using IntentAccountSync, an `AppShortcutsProvider`, and a `ControlWidgetButton` (iOS 18) in the widget extension. Keep the INExtension handlers. No new Spotlight content beyond contacts. Respect passcode lock and account state.
- **Docs:** https://developer.apple.com/documentation/appintents ; https://developer.apple.com/documentation/widgetkit/controlwidget
- **Risk:** medium.
- **Measurement:** Shortcuts discoverability; Action button to typed Saved Messages time; extension memory.
- **Effort:** large
- **Status:** open

### IOS-LOC-1: Live location keeps GNSS on while stationary
- **Severity:** medium
- **Scope:** iOS only (DeviceLocationManager is not in the Mac paths list).
- **Evidence:** `DeviceLocationManager.swift:76-79` NearestTenMeters, `.other`, `pausesLocationUpdatesAutomatically = false`; no CLLocationUpdate, CLBackgroundActivitySession or CLServiceSession. R3 is partial.
- **Change:** iOS 17+ alternate backend: `CLLocationUpdate.liveUpdates(.otherNavigation)`, publish the last location while `update.stationary`, hold a `CLBackgroundActivitySession` (and `CLServiceSession` on iOS 18). Keep CLLocationManager for iOS 15-16 and for heading. No change to accuracy or send interval. Behind a flag until the first-update-after-movement latency is measured.
- **Docs:** https://developer.apple.com/documentation/corelocation/cllocationupdate ; WWDC23 'Discover streamlined location updates'.
- **Risk:** medium (latency when movement starts; Swift concurrency inside a SwiftSignalKit queue).
- **Measurement:** Location Energy over a 1-hour stationary session; time to first update after walking.
- **Effort:** medium
- **Status:** open

### IOS-DEPR-1: Dead UIWebView and UILocalNotification branches; legacy Telegram/Watch not built
- **Severity:** low
- **Scope:** iOS only.
- **Evidence:** `ChatDocumentGalleryItem.swift:122-127` UIWebView under an always-true iOS 11 check (minimum 15.0, `Telegram/BUILD:202`); `SharedNotificationManager.swift:456` UILocalNotification; `Telegram/Watch` (646 files) referenced by nothing.
- **Change:** delete the two else branches. Delete `Telegram/Watch` in its own commit (owner decision: upstream merge churn).
- **Docs:** https://developer.apple.com/documentation/uikit/uiwebview
- **Risk:** low.
- **Measurement:** `nm` the release binary for UIWebView; altool validate warnings.
- **Effort:** small
- **Status:** open

### IOS-DEPR-3: Microphone permission uses deprecated AVAudioSession.requestRecordPermission
- **Severity:** low
- **Scope:** iOS only.
- **Evidence:** `DeviceAccess.swift:386`, `TGVideoMessageCaptureController.m:1447`. The watch app already uses AVAudioApplication.
- **Change:** `AVAudioApplication.requestRecordPermission` / `.shared.recordPermission` on iOS 17+, old call under `#available` for 15-16; skip the prompt when already granted.
- **Docs:** https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)
- **Risk:** very low.
- **Measurement:** fresh-install prompts on iOS 17+ and 16; two fewer warnings.
- **Effort:** small
- **Status:** done (branch mod/ios-platform); no unit test possible (system permission API), verify by the fresh-install prompts

### iOS-CONC-1: GraphCore DisplayLinkService is a 60 Hz timer with main.sync
- **Severity:** low
- **Scope:** shared core (GraphCore); AppKit path unchanged.
- **Evidence:** `GraphCore/Sources/Helpers/DisplayLinkService.swift:40-45` and the GraphCore2 copy at :205-209.
- **Change:** CADisplayLink on the main run loop with `preferredFrameRateRange(30, 120, preferred 60)`, delta from `targetTimestamp - timestamp`, paused when no listeners. Reuse the shared display-link wrapper (R14, 3cd4aadf). Same public API. iOS only under `#if os(iOS)`.
- **Docs:** https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange
- **Risk:** low.
- **Measurement:** Animation Hitches and thread wakeups on the channel statistics screen.
- **Effort:** small
- **Status:** open

### iOS-CONC-2: BlurredImageNode blocks a worker with Queue.mainQueue().sync
- **Severity:** low
- **Scope:** iOS only (`TelegramUI/Components/Settings/WallpaperGalleryScreen/Sources/BlurredImageNode.swift`).
- **Evidence:** `Queue.mainQueue().sync { blurLayer.draw(...) }` at ~100 from a background queue; unused `sync(on:)` helper. TGCache's main sync is required (synchronous return, LegacyComponents-only) and stays.
- **Change:** switch to async (result is only drawn), drop older results with a generation counter, delete the unused helper. Leave TGCache, GPUImageOutput and PGVideoMovie.
- **Docs:** https://developer.apple.com/documentation/xcode/improving-your-app-s-responsiveness
- **Risk:** low.
- **Measurement:** Thread State Trace during a wallpaper blur drag.
- **Effort:** small
- **Status:** open

### iOS-CONC-4: Thread.sleep retry on the audio-session queue
- **Severity:** low
- **Scope:** shared module TelegramAudio, iOS file only (`Sources/ManagedAudioSession.swift`; the Mac uses `Macos/`). MediaDataReader is in MediaPlayer (shared core).
- **Evidence:** `ManagedAudioSession.swift:1040` sleeps 2 s after a failed `setActive(false)` on the serial queue; `MediaDataReader.swift:359-361` polls up to 100 times at 1/60 s. StorageBox and AccountManagerImpl sleeps are pre-UI and stay.
- **Change:** replace the sleep with `queue.after(2.0)` and a generation guard so a delayed retry never deactivates a session that a later request activated. Cap MediaDataReader polling (a few retries, then report failure) or wait on the reader's status.
- **Docs:** https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)
- **Risk:** medium (audio-session state ordering).
- **Measurement:** System Trace around call and voice-message transitions with a forced deactivate failure.
- **Effort:** small
- **Status:** open

### iOS-STICKERS-1: All AnimatedStickerNodes share one default-QoS serial queue
- **Severity:** low
- **Scope:** iOS only (AnimatedStickerNode).
- **Evidence:** `AnimatedStickerNode.swift:11` `sharedQueue = Queue()`, assigned at 338; frame-source creation (gunzip, makeLottieInstance) and per-frame `takeFrame` run there. Stall only on a cold cache or first loop.
- **Change:** pool of 3 serial queues at `.userInitiated`, assigned round-robin per node; `AnimatedStickerBackgroundGate` gets its own lock. Behind a flag until profiled.
- **Docs:** Energy Efficiency Guide, QoS.
- **Risk:** medium (cross-node ordering assumptions; parked-timer registry).
- **Measurement:** cold-cache sticker chat open: time to first frame of the 5th sticker, missed frames.
- **Effort:** medium
- **Status:** open

### iOS-STICKERS-2: Per-frame playbackStatus.set with no subscriber
- **Severity:** low
- **Scope:** iOS only.
- **Evidence:** `AnimatedStickerNode.swift:658` and `:780` set the status Promise every frame inside the main hop; the only reader is the `status` getter at 291.
- **Change:** set the status only when someone subscribed (counted in the getter). No coalescing of main hops (speculative; not in scope).
- **Risk:** low.
- **Measurement:** main-thread self time in `Promise.set` and Signal allocations per second in a sticker-heavy chat.
- **Effort:** small
- **Status:** open

### iOS-GIFGRID-1: BatchVideoRenderingContext decodes all tiles serially behind one flag
- **Severity:** medium
- **Scope:** iOS only (`TelegramUI/Components/BatchVideoRendering`, not in the Mac paths list).
- **Evidence:** `BatchVideoRenderingContext.swift:241` one default-QoS queue; `updateRendering` returns while `isRendering`; ~378-395 advance every tile serially; reader open happens in the same pass. The file's own comment (95-101) admits one stuck reader freezes all tiles.
- **Change:** per-context serial queues (ReadingContext moves off the single QueueLocalObject queue), a small concurrent pass bounded by performance cores, one pass in flight per tile instead of a global flag, reader open as a separate step. Keep `HardwareDecoderBudget` slots and thread-safe `releaseReader()`.
- **Docs:** https://developer.apple.com/documentation/dispatch/dispatchqueue/2016088-concurrentperform
- **Risk:** medium.
- **Measurement:** Points of Interest around each pass on a 20+ tile GIF panel; per-tile frame interval p95.
- **Effort:** medium
- **Status:** open

### iOS-MEDIA-THREADS-1: Thread per FFmpeg source; first-frame signals never complete on failure
- **Severity:** medium
- **Scope:** shared core (MediaPlayer) for the thread pool; iOS-only TelegramUI for the completion fix.
- **Evidence:** `FFMpegMediaFrameSource.swift:130` and `UniversalSoftwareVideoSource.swift:485` start a Thread per source. `TelegramUI/Sources/FetchCachedRepresentations.swift:46-66` and `74-95` handle only a non-nil image with successful JPEG data; nil image, JPEG failure and `.waitingForData` never complete, and `keepAlive(videoSource)` holds the thread and decoder.
- **Change:** step 1 (do first): complete the signal on every outcome (with a timeout for `.waitingForData`) and release the source. Step 2: run source task loops on a bounded pool of long-lived workers with explicit QoS, with the FFmpeg interrupt context stored per task instead of in the thread dictionary; pool width above the number of simultaneous blocking sources. Step 2 behind a flag.
- **Docs:** https://developer.apple.com/documentation/foundation/thread/qualityofservice
- **Risk:** low (step 1), medium (step 2).
- **Measurement:** thread count while scrolling a video channel and playing three voice notes; thread count returns to baseline after leaving.
- **Effort:** medium
- **Status:** open

### iOS-QOS-1: iOS ThreadPools use threadPriority, not QoS
- **Severity:** low (owner deferred: shared-core plan 2.3, pending iOS measurement)
- **Scope:** shared core (SSignalKit; Mac already uses QoS).
- **Evidence:** `ThreadPool.swift:139-146` iOS branch sets `threadPriority`; mapping helper at 130. Pools: softwareVideoWorkers, fetchPhotoWorkers (0.2), AnimatedStickerUtils (0.5). SwiftSignalKit2 has a copy.
- **Change:** use `qualityOfService` on iOS behind a flag that defaults off; keep the video-sticker pool at `.userInitiated` if first frames regress.
- **Docs:** https://developer.apple.com/documentation/foundation/thread/qualityofservice
- **Risk:** low to medium.
- **Measurement:** E-core share of pool work and video-sticker first-frame latency, A/B on device.
- **Effort:** small
- **Status:** open

### iOS-METAL-STICKERS-1: One MTLCommandQueue per CompressedImageRenderer
- **Severity:** low
- **Scope:** iOS only (AnimationCompression).
- **Evidence:** `CompressedImageRenderer.swift:169` and `AnimationCompressor.swift:258` call `makeCommandQueue()` per instance; default sticker mode `.gpuLarge` uses this path.
- **Change:** one queue per device in the shared context; labels on command buffers.
- **Docs:** Metal Best Practices Guide, command queues.
- **Risk:** low.
- **Measurement:** command queues alive on the sticker panel (Metal System Trace).
- **Effort:** small
- **Status:** open
