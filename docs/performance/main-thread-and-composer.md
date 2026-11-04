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
