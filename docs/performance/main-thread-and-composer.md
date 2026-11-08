# Main-thread and composer hot paths

## Main-thread and composer hot paths (2026-11)

Invariants the compiler does not check; each has a test.
- **Composer height measure** (`ChatInputTextView.textHeightForWidth`): with unchanged width/right inset the
  measure stack replaces only the edited range (`replaceChangedRange`) instead of a full relayout. Anything whose
  layout depends on a *neighbouring* paragraph must take the full path: block quotes do (paragraph spacing reads
  the previous/next character), so `replaceChangedRange` returns false when either string has one. A new
  attribute with that kind of dependency must be added there. `//submodules/TelegramUI/Components/Chat/ChatInputTextNode:ChatInputTextNodeTests`
  compares heights against a full relayout.
- **Rich rendering** (spoiler dust, custom-emoji overlays) runs once per text change: while
  `ChatInputTextView.isHandlingTextChange` (inside `textViewDidChange`) `updateRichRendering` only marks itself
  pending and runs from `didHandleTextChange`. It must stay a pure function of the current text and layout.
- **`refreshChatTextInputAttributes`** compares the rebuilt string with the storage after undoing the storage's
  font substitution (`NSOriginalFont`); only a real difference strips and re-adds the attributes.
- **Draft link detection** is `ChatInputUrlDetector.shared` (TextFormat): per-line cache (a link never spans a
  newline), last-text memo. `ChatInterfaceState.withChangedInputLanguage` returns nil for an unchanged language,
  and the controller then skips the presentation pipeline.
- **`AccountContext.animatedEmojiStickerKeys`** is the cached `Set` of `animatedEmojiStickersValue.keys`; never
  build that set per keystroke.
- **Premium-lock blurred badge** (`DCTMultiAnimationRendererImpl`): made on the frame-loading queue for the first
  target with a `blurredRepresentationTarget`; main only assigns it.
- **Profile list tabs**: `PeerInfoListRowLayout` skips relayout of a row for unchanged size/insets; a row's
  message item only changes in `bind`.
- **Touch-down** (`keyboardGestureStart`, WindowContent): the first-responder tree walk runs only while the
  keyboard is up.
- **Debug Settings** entries are built by `debugControllerEntries(environment:...)`; ids must increase in append
  order or ItemList traps. `//submodules/DebugSettingsUI:DebugSettingsUITests` checks every combination and that
  settings stored by older builds (keys of removed switches) still decode.
- **Debug log exports** (Send Logs and its kinds, Profile Logs, MetricKit Reports, Crash Logs and the post-crash
  prompt, the chat menu's Send Logs) all go through `presentDebugLogExport` (`DebugLogExport.swift`): "Via
  Nanogram…" (a chat the user picks), "Via Email…" (share sheet without a Mail account), "Other Apps…". Each kind
  only supplies its files. Nothing is sent to a fixed chat or bot (the crash log used to go to
  `@iOSCrashReportsBot`); `DebugLogExportTests` scans the module's sources for that and pins the Nanogram names.
  One export runs at a time (`DebugLogExportGate`, under the loading overlay). A chat send references the prepared
  files by path (`LocalFileReferenceMediaResource`, never read on main) and keeps their directory until the messages
  have left. MetricKit reports are zipped unchanged, as JSON.
- **MetricKit**: `CrashReportCollector` keeps metric/diagnostic reports in `MetricReportStore`
  (`Library/Application Support/CrashReports/MetricKit`, deduplicated by content, bounded), via `MetricManager` on
  iOS 27+ and the MX payloads on iOS 15-26; crash diagnostics still feed `CrashReportStore` from MX on all
  versions. Nothing is uploaded; Debug Settings ▸ Send MetricKit Reports is the only way out. Host test:
  `//submodules/CrashReporting:CrashReportingTests`.
- **Signposts**: `PerformanceSignposts` (Display) intervals `chatHistoryEntriesForView` and `composerKeystroke`.
- **Chat open: defer non-visible setup** (Debug Settings ▸ "CHAT OPEN (PERFORMANCE)", `ExperimentalUISettings.chatOpenDeferSetup`,
  default off, main app only). `ChatControllerImpl` reads the switch once in `init` (standard, non-previewing chats only) into
  `openSetup` (`DeferredSetup`, SwiftSignalKit). With it off, `openSetup.run` executes the work at once in place, so the code path
  is the original one. With it on, the setup submitted through `openSetup.run` runs from `viewDidAppear` on the next main-queue
  turn: nameColor, botCallbackAlert, audio/video recorder, typing/sticker/recording activity (init); translation host (iOS 18),
  send-as list, network-speed notices, `GlobalControlPanelsContext` and its state subscription (`loadDisplayNodeImpl`). Anything
  that can change the first frame (presentation data, content data, history, sticker/download settings, read state, network title) stays
  synchronous. Attribution signposts (category Performance): `chatInit` (whole init) with `chatInitInteraction`,
  `chatInitDisplayNode`, `chatInitReloadLocation`, `chatInitPresentationData`, one `chatInitDeferrable` per deferrable item,
  `chatInitDeferredSetup` (the flush) and `chatFirstLayout`. Tests: `//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKitTests`
  (`DeferredSetupTests`), `//submodules/DebugSettingsUI:DebugSettingsUITests` (`ChatOpenSwitchTests`),
  `//submodules/TelegramUIPreferences:TelegramUIPreferencesTests`.
- **Chat open: prewarm wallpaper pattern** (Debug Settings, same section, `ExperimentalUISettings.chatOpenPrewarmWallpaperPattern`, default on).
  `WallpaperPatternPrewarmer` renders the chat wallpaper's pattern on a utility queue into the pattern cache 3 s after the root
  controllers exist (and after wallpaper changes), under the key and with the draw arguments the chat uses, so the first chat open takes
  the cache-hit path (~36 ms less on main). iPhone, pattern wallpapers only. Test: `//submodules/WallpaperBackgroundNode:WallpaperPatternPrewarmPlanTests`.
- **Chat-scroll experiments** (Debug Settings ▸ Chat scroll, both off by default): "Chat rows: prepare layout ahead" and
  "Chat rows: reuse row views". A prepared row is used only for an exactly equal `ChatRowPrepKey`; `ChatControllerInteraction`
  properties that a row's layout reads must keep the `rowPrepEpoch` `didSet` (a new such property needs it too). A row view
  type is pooled only when it overrides `supportsRowReuse` and `prepareForRowReuse` and its ledger test passes. Details:
  `docs/chat/corelist-chat-history-backend.md`.
