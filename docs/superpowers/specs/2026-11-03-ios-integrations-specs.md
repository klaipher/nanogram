# Nanogram iOS: system integrations review (2026-11-03)

A read-only review of how Nanogram for iOS (`/Users/klaipher/Projects/nanogram-ios`, bundle `org.klaipher.Nanogram`)
works with the rest of the system. It covers the Share extension and share-sheet suggestions, the notification service
and content extensions, Siri intents, widgets, Spotlight, URL schemes, the document picker, pasteboard, drag and drop,
screen sharing, location and the photo library. Three reviewers (share, notifications, intents and widgets, app
integrations) wrote findings, and two adversarial verifiers re-read every cited line. Only confirmed or corrected
findings are kept. Corrections are marked **Corrected**. Nothing was built, run or profiled, so every size, time and
memory figure is an estimate from reading the code.

- **Code state.** Reviewed at HEAD `a1d25f70`. `NotificationService.swift` and `AppDelegate.swift` were being edited
  by other workflows, so they were read with `git show HEAD:`. Their line numbers ("NS HEAD", "AppDelegate HEAD") can
  sit 13-40 lines away from older citations. HEAD is now `76b150c4`; the one commit in between that touches this area,
  `806ff160`, is noted in I-25. Re-check line numbers before starting.
- **Fork or upstream.** `b46f1ec6` is a root commit that already contains fork code, so git cannot separate upstream
  from fork. Since then, the share sources (`ShareItems`, `ShareExtensionContext`, `ShareScreen`), `TelegramIntents`,
  `TodayViewController` and `NotificationContentContext` are unchanged. The fork's only edits in these areas are
  `ShareRootController` (ShareProcessActivity), `WidgetDataContext` (polling, `9bc6231a`), one line in
  `OpenResolvedUrl`, and `397ac282` (the communication-notification entitlement, which switched on the notification
  extension's donations). Almost everything below is inherited behaviour, not a fork regression.
- **Minimum OS.** iOS 15.0, confirmed at `Telegram/BUILD:170`.
- **Debug caveat.** `ShareExtensionContext.swift:317-321` sets `immediatePeerId = nil` under `#if DEBUG`. Tapping a
  share-sheet suggestion never preselects that chat in debug builds, so test I-6 and I-12 on release or TestFlight
  builds only.
- **Effort**: S = a few lines, M = one file or a few call sites, L = a design change across modules.

Status values: `todo`, `in progress`, `done (<commit>)`, `dropped (<reason>)`.

| Area | high | medium | low | bug | perf | memory | modernization | Total |
|---|---|---|---|---|---|---|---|---|
| Share | 5 | 5 | 3 | 8 | 2 | 2 | 1 | 13 |
| Notifications | 1 | 0 | 8 | 3 | 3 | 1 | 2 | 9 |
| Intents / Widgets / Shortcuts / Spotlight | 1 | 4 | 6 | 6 | 3 | 0 | 2 | 11 |
| Other integrations | 0 | 5 | 5 | 2 | 3 | 2 | 3 | 10 |
| **all** | **7** | **14** | **22** | **19** | **11** | **5** | **8** | **43** |

---

## Share (Share extension and share-sheet suggestions)

### I-1. A failed send is reported as success — `done (dc13db12)`

- **Implementation (2026-11-03)**: `sentItems` maps the send error to `ShareControllerError.generic` instead of catching it, so the coordinator's `fail` alert shows and the sheet reopens; `.done` follows only a successful send. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: high. **Category**: bug.
- **Evidence**: `submodules/TelegramUI/Components/ShareExtensionContext/Sources/ShareExtensionContext.swift:480-491`:
  `let sentItems = sentShareItems(...) |> `catch` { _ -> Signal<Float, NoError> in return .complete() }` … `|> then(.single(.done))`.
  `submodules/ShareItems/Sources/ShareItems.swift:575-578` maps every `StandaloneSendMessagesError` to `Void`. The
  error branch in `ShareScreenSendCoordinator.swift:229-242` (`self.fail(text, peer:)`) is never reached. The error
  carries `reason: PendingMessageFailureReason?` (`StandaloneSendMessage.swift:32-35`, `:637-643`).
- **Effect**: when the server rejects the send (slow mode, flood wait, media banned in the target chat, paid-message or
  Stars refusal), the sheet shows the success check, plays the success haptic and closes. Nothing was sent and no
  error is shown.
- **Fix**: make `sentItems` a `Signal<ShareControllerExternalStatus, ShareControllerError>`. Map the send error to
  `.generic`, or to a specific message built from `PendingMessageFailureReason`, instead of catching it. Emit `.done`
  only on success, so the existing `fail(...)` alert appears.
- **Risk**: low. Only the failure path changes. Check that `fail` keeps the sheet open for retry or cancel.
- **How to verify**: on a device, share a photo to a group where you cannot send media, or to a chat in slow mode
  right after sending there. Today: success check. After: error alert, and nothing in the chat on another device.
  **Corrected**: Airplane Mode after upload does not reproduce it, because MTProto keeps retrying (a stall, not an
  error).
- **Effort**: S. **Confidence**: high.

### I-2. A failed or unsupported attachment leaves the share sheet spinning forever — `done (dc13db12)`

- **Implementation (2026-11-03)**: `shareItemDictionaries` (ShareItems) fails with `.generic` when a provider errors, completes without an item or yields a non-dictionary; every `.never()` in `preparedShareItem` is `.fail(.generic)`. NSData image items and nil provider values no longer hang either. An audio-only movie is now sent as a file instead of failing. Tests: `ShareItemsTests` (`ShareItemDictionariesTests`). Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: high. **Category**: bug.
- **Evidence**: `ShareItems.swift:385-388`: the wrapper around each item-provider `MTSignal` is
  `dataItem.start(next: …, error: { _ in }, completed: { subscriber.putCompletion() })`, inside a `then` chain with
  `take(1)`, so an error neither completes nor fails. `preparedShareItem` returns `.never()` at `:91` (UIImage scale
  fails), `:336` (unreadable audio) and `:373` (unknown dict). Producers do fail:
  `submodules/ShareItems/Impl/Sources/TGItemProviderSignals.m:69` (unreadable file URL), `:424` (`[MTSignal fail:nil]`
  for a movie with no video track) and every `putError:nil` after a `loadItem` error. The loading UI has no cancel
  (`ShareLoadingContainerNode.swift:64/68`, `cancelEnabled: false`).
- **Effect**: sharing an audio-only `.mov`/`.m4v` (conforms to `public.movie`, takes the video path, fails at `:424`),
  an iCloud-only file that is not downloaded, or any item whose provider errors shows "preparing" forever. Nothing is
  sent, and the user has to swipe the extension away while `ShareProcessActivity` keeps the process alive.
- **Fix**: in the wrapper, forward `MTSignal` errors as `subscriber.putError(.generic)` (type becomes
  `Signal<[String: Any], PreparedShareItemError>`). Replace each `.never()` in `preparedShareItem` with
  `.fail(.generic)`. Optional: skip a failed item and send the rest with a notice.
- **Risk**: low. `ShareControllerError.generic` → `fail` already exists.
- **How to verify**: share an audio-only `.mov` from Files. Before: endless spinner. After: error alert. Unit test:
  feed a failing `MTSignal` into `preparedShareItems` and expect `.generic`.
- **Effort**: S. **Confidence**: high.

### I-3. About 5 MB leaked per shared photo (CGImage never released), orphaned temp JPEGs, unguarded CFRelease — `done (dc13db12)`

- **Implementation (2026-11-03)**: One ImageIO helper (`scaledJpegImageFromSource:maxPixelSize:`) releases the thumbnail and destination on every path, checks the source and destination for NULL and encodes into `NSMutableData` (no temp files). Tested through `ScaledJpegImageTests`; the leak itself was not measured with Instruments. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: high. **Category**: memory.
- **Evidence**: `TGItemProviderSignals.m:219-256`: `CGImageRef image = CGImageSourceCreateThumbnailAtIndex(src, 0, options);`
  (`:227`, a +1 Create; ARC does not manage CF types) is never `CGImageRelease`d on any path, including the Finalize
  failure at `:243`. `CFRelease(src)` at `:228` has no NULL check, and `destination` (`:237`) is not checked either.
  Each image is written to `NSTemporaryDirectory()/img<rand>` (`:235-236`) and never removed.
- **Effect**: each shared photo leaks its decoded 1280-px thumbnail for the life of the extension (1280×960×4 ≈ 4.9 MB
  for a 4:3 photo; ten photos ≈ 49 MB). Together with TelegramUIFramework, Postbox and the network, this pushes the
  extension toward its memory limit, so a jetsam kill around 15-20 photos is likely (estimate, not measured). tmp grows
  by one JPEG per photo. The NULL crash needs ImageIO to return NULL, which is rare for host-provided image URLs.
- **Fix**: `CGImageRelease(image)` on every exit path; guard `src` and `destination` for NULL; encode to memory with
  `CGImageDestinationCreateWithData(NSMutableData)` instead of a temp file. Or port to Swift with a `defer`-scoped
  ImageIO helper like the app's `downsampledPhotoLibraryImage`.
- **Risk**: very low.
- **How to verify**: Instruments (Leaks, Allocations) attached to the Share extension, share 10 photos from Photos:
  today ~10 leaked ~4.9 MB CGImage blocks, after the fix none. Compare the extension footprint after 20 photos.
- **Effort**: S. **Confidence**: high on the leak and temp files; the jetsam point is an estimate.

### I-4. Use-after-free in round-video detection, plus a full-resolution frame copy and wrong row stride — `done (dc13db12)`

- **Implementation (2026-11-03)**: The frame is generated at most 64×64 and drawn into an RGBA bitmap of known stride before the corners are read; the buffer is freed after the checks. A frame that cannot be read means "not round" instead of failing the share. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: medium. **Category**: bug. (Found during verification.)
- **Evidence**: `TGItemProviderSignals.m:377-391`: `CFRelease(pixelData)` runs before `isWhitePixel(...)` reads `data`
  in the return expression. It runs for every square, non-Boomerang video (`:443-451`). `detectRoundVideo`
  (`:340-372`) asks the image generator for a full-resolution frame (no `maximumSize`) and indexes pixels with
  `width*4` instead of `bytesPerRow`.
- **Effect**: reads freed memory. A 1080² frame is about 4.7 MB, large enough that the allocator may unmap it on free,
  which would crash the extension. With padded rows the corner checks can misclassify the video as round or not.
- **Fix**: release `pixelData` after the checks; set `imageGenerator.maximumSize = CGSizeMake(64, 64)`; index with
  `CGImageGetBytesPerRow`.
- **Risk**: very low.
- **How to verify**: share a square 1080² video from Photos with Address Sanitizer or Guard Malloc enabled on the Share
  extension; today it reports a use-after-free.
- **Effort**: S. **Confidence**: high on the free; medium on it crashing in practice.

### I-5. Blank, undismissable extension when no account is ready (never signed in, logged out, migration pending, DB unavailable) — `done (dc13db12)`

- **Implementation (2026-11-03)**: Before opening any account the extension reads the records: none signed in → `.unauthorized` (the `Share_AuthTitle` alert). No primary account within 10 s (upgrade pending, unreadable database) or completing without one → the same alert. `beginNewAuth` runs only when `applicationBindings.isMainApp`. Not verified on a device. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: high. **Category**: bug.
- **Evidence**: `ShareExtensionContext.swift:402-407`:
  `context.sharedContext.activeAccountContexts |> filter { $0.primary != nil } |> take(1)`. `MakeTempAccountContext.swift:50-53`
  returns `.complete()` when there is no primary. With no records, `combineLatest([])` emits `[]`
  (`Signal_Combine.swift:248-249`), so primary is nil. Every `ShareAuthorizationError` comes from `castError`
  (`:424`, `:437`), so the `Share_AuthTitle` alert at `:900-909` is unreachable and `completed: {}` does nothing; the
  code that used to `.fail(.unauthorized)` is commented out at `:332-378`. `Account.swift:323-324` turns an openPostbox
  `.error` into `.upgrading(0.0)`, and `displayUpgradeProgress` is a no-op in the extension
  (`MakeTempAccountContext.swift:43`). `SharedAccountContext.swift:824-826` calls `beginNewAuth` with no `isMainApp`
  gate, so the extension writes an auth record into shared accounts-metadata and starts an unauthorized network.
- **Effect**: sharing to Nanogram before the first login, after logging out of every account, after an update that
  needs a Postbox upgrade the app has not run, or while the database cannot be opened shows a blank full-screen
  extension with no Cancel. The user has to kill the host app. The extension also changes shared login state.
- **Fix**: before `makeTempContext`, read the accountManager records once. With no authorized record, fail with
  `.unauthorized` so the existing alert appears. Treat `.upgrading`/`.error`, or no primary within ~5-10 s, the same
  way ("Open Nanogram first"). Gate `beginNewAuth` on `applicationBindings.isMainApp`.
- **Risk**: low. Only paths that hang today change; keep the passcode flow ahead of the alert.
- **How to verify**: (a) fresh install, share a photo to Nanogram; (b) log out of all accounts, share. Today: blank.
  After: the `Share_AuthTitle` alert, OK dismisses, and accounts-metadata gains no auth record (log
  `transaction.getRecords()`).
- **Effort**: M. **Confidence**: high on the code path.

### I-6. A share-sheet suggestion opens the share UI in the wrong account — `done (dc13db12)`

- **Implementation (2026-11-03)**: Identifiers stay `tg<peer id>` (Siri's `siriSendMessageTarget` and the system's ranking already use it; the account-qualified form is parsed but not written). Every donor now donates only from the suggestions account (I-12), so the extension and AppDelegate open a suggestion in `IntentsSettings.account` (`SendMessageSuggestions.accountPeerId`), falling back to the primary/current account when it is signed out. Tests: `NotificationServiceTests` (`SendMessageSuggestionsTests`). Release/TestFlight only (debug never preselects). Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: high. **Category**: bug.
- **Evidence**: donations come only from the suggestions account: `TelegramIntents.swift:69-71`
  `if let accountId = settings.account, accountId != account.peerId { return .single([]) }`. That account is pinned
  once (AppDelegate HEAD `:3402-3415`) and is user-selectable, independent of the current account. Identifiers carry
  no account: `customIdentifier`/`conversationIdentifier` = `"tg\(peer.id.toInt64())"`. The extension reads
  `recipients.first.customIdentifier` (`ShareExtensionContext.swift:322-329`) and looks the peer up in the primary
  context (`ShareScreen.swift:359-364`; context = `accounts.primary`, `:407`, `:418`). The account-switch logic
  survives only in the commented block `:332-378`. AppDelegate HEAD `:2928-2932` opens with `accountId: nil`.
- **Effect**: with two or more accounts, when the open account differs from the suggestions account: if that account
  also knows the peer, it is preselected and the item is sent from the wrong account (for "Saved Messages", account
  A's own user is preselected inside account B, so the content goes as a DM to A). Otherwise nothing is preselected
  and the tap is lost. Release/TestFlight only (debug caveat above).
- **Fix**: when an `INSendMessageIntent` is present, read `IntentsSettings.account` and use that context as the
  initial one (restore the commented logic), falling back to primary. Better: make the identifier account-qualified
  (`tg<accountPeerId>:<peerId>`, like `IncomingCallNotifications.callBackIdentifier` from `806ff160`), still accept
  `tg<peerId>`, and resolve it in both the extension and AppDelegate.
- **Risk**: low. The old form stays parseable.
- **How to verify**: TestFlight, accounts A and B. Suggestions account = A, switch the app to B, message Saved Messages
  in A, then share a photo and tap the Nanogram "Saved Messages" suggestion. Today: B opens with A's user selected or
  nothing. After: A opens with Saved Messages selected.
- **Effort**: S. **Confidence**: high.

### I-7. "Send in HD" in the share extension sends silently at standard quality — `done (dc13db12)`

- **Implementation (2026-11-03)**: "Send in HD" sends normally (not silently); `ShareScreen.sendsInHighQuality` is read by the extension's send closure and `itemSignalsForInputItems:highQuality:` / `preparedShareItems(highQuality:)` scale photos to a 2560-px long side. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: medium. **Category**: bug.
- **Evidence**: `submodules/TelegramUI/Components/ShareScreen/Sources/ShareScreen.swift:550-551`:
  `items.append(sendItem(data.strings.Attachment_SendInHd, icon: "Chat/Context Menu/QualityHd", silently: true))`.
  `sendItem` only toggles `silently`. `canSendInHighQuality` is set at `ShareExtensionContext.swift:545-558`; the
  `.fromExternal` send closure (`:497-534`) has no quality parameter; `TGItemProviderSignals.m:177` hard-codes
  `maxSize = CGSizeMake(1280.0, 1280.0)`. Inherited from upstream `ShareControllerNode`.
- **Effect**: users who pick Send in HD get a muted notification on the recipient's side and a 1280-px JPEG, the same
  as a normal send.
- **Fix**: thread a quality flag through `ShareScreen.Subject.fromExternal` into
  `TGItemProviderSignals itemSignalsForInputItems:highQuality:`; use a 2560-px long side for HD and send normally
  (not silently).
- **Risk**: larger photos use more memory and upload time in the extension; land I-3 first.
- **How to verify**: long-press Send, choose Send in HD; the received photo's long side is 2560, and the recipient gets
  a normal notification.
- **Effort**: M. **Confidence**: high.

### I-8. Share-to-Story leaves full-size copies in the app group forever — `done (dc13db12)`

- **Implementation (2026-11-03)**: The extension copies attachments with `copyItem` under their own extension, opens the app only if at least one copy succeeded (else an error alert), and sweeps sessions older than a day. The app decodes photos, moves videos into `EngineTempBox`, deletes the session directory and sweeps stale ones (`SharedStorySession`, tested in `SharedStorySessionTests`). Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: medium. **Category**: bug.
- **Evidence**: `ShareExtensionContext.swift:564-605` writes each attachment to
  `rootPath + "/share/stories/<sessionId>/<n>.jpg|.mp4"` (images through `Data(contentsOf:)`, always named `.jpg`).
  The only reader, `OpenResolvedUrl.swift:1270-1325`, never removes the directory; grep finds no other reference to
  `share/stories`. (A HEIC named `.jpg` still decodes, because `UIImage(contentsOfFile:)` sniffs the content.)
- **Effect**: every story shared from another app leaves its original media (tens to hundreds of MB for video) in the
  shared container indefinitely, outside Storage Usage. A failed copy still opens the app with an empty session.
- **Fix**: in the extension, copy with `FileManager.copyItem`, keeping the real extension, and open the app only when
  at least one file was written. In the app, move videos into `EngineTempBox`, delete the session directory once the
  MediaEditor subjects exist, and sweep `share/stories/*` older than a day at launch.
- **Risk**: low. Make sure no video subject still points at the deleted path.
- **How to verify**: `du -sh <appgroup>/telegram-data/share/stories` before and after sharing a video to Story (sim:
  `xcrun simctl get_app_container <udid> org.klaipher.Nanogram groups`). Today it grows; after it empties once the
  editor opens.
- **Effort**: S. **Confidence**: high.

### I-9. The extension opens and syncs every logged-in account before showing any UI — `dropped (L design change)`

- **Implementation (2026-11-03)**: Opening only the target account changes how the account switcher gets its peers and needs before/after measurements on a device with several accounts; not done blind. I-5's 10 s cap bounds the worst case. Left for a measured follow-up.

- **Severity**: medium. **Category**: perf.
- **Evidence**: `SharedAccountContext.swift:659-699` opens a Postbox for every record and `combineLatest` waits for all
  of them; `:769` calls `resetStateManagement` on each. `Account.swift:1692-1698` runs the state-manager reset
  (getDifference), contact sync and sticker-pack management even for supplementary accounts (only history preload is
  gated). `ShareExtensionContext.swift:410-419` then reads every account's peer. Before that, `viewDidLayoutSubviews`
  blocks on two semaphores (`:270-288` logging settings, `:295-307` presentation settings).
- **Effect**: time to first frame and resident memory grow with the number of accounts (an SQLCipher connection,
  caches, a network context and sync work per account) inside a memory-limited process. Not measured.
- **Fix**: in the extension, open only the target account (the suggestions account for a suggestion tap, else
  primary), show the UI, and open the others lazily when the account switcher opens. Skip `resetStateManagement` for
  non-selected accounts in extensions. Merge the two semaphore reads into one transaction off the layout pass. Add
  signposts for launch → sheet visible.
- **Risk**: medium. The account menu currently needs all peers up front.
- **How to verify**: signpost `loadView` → first ShareScreen layout; compare 1 vs 3 accounts in Instruments (Points of
  Interest, Allocations) on device.
- **Effort**: L. **Confidence**: high on the code path; the cost is not measured.

### I-10. No cap on attachment count; all uploads start at once; the data path decodes full-resolution images — `done (dc13db12)`

- **Implementation (2026-11-03)**: Items are prepared and uploaded at most 3 at a time (`combineLatestLimitingConcurrency`, tested); the data path downsamples with ImageIO instead of drawing a full-size `UIImage`; the activation rule caps a share at 100 attachments. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low. **Category**: memory.
- **Evidence**: **Corrected**: items are loaded one after another (`then` chain, `ShareItems.swift:390-396`), but all
  dicts are held and `combineLatest` then starts every upload or transcode at once (`:403-406`). The activation rule
  has no count limit and matches `public.data` (`Telegram/BUILD:1113-1130`). On the data path, `UIImage(data:)` +
  `scalePhotoImage` decode the full image before scaling (`:264`, `:294`); a 48 MP HEIC is ~195 MB RGBA.
- **Effect**: sharing dozens of photos or videos runs dozens of uploads and transcodes in parallel inside the
  extension's memory limit; one large image on the data path can exceed it alone.
- **Fix**: prepare and upload 2-3 items at a time; cap the count (`@count <= 100` in the rule, or a friendly error);
  downsample with `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize` on the data path.
  (The round-video probe is in I-4.)
- **Risk**: low.
- **How to verify**: share 50 photos with Instruments attached to the extension and compare peak footprint; share a
  48 MP HEIC via a data-only provider and watch the peak.
- **Effort**: M. **Confidence**: medium.

### I-11. Legacy NSItemProvider and synchronous AVAsset APIs, and dead availability checks in the share path — `done (dc13db12, I-11 follow-up)`

- **Implementation (2026-11-03)**: Done: item-type checks on every `loadItemForTypeIdentifier` result, video `tracks`/`metadata`/`duration` loaded asynchronously before they are read (ObjC and `ShareItems.swift`), dead availability checks removed in the extension and `TelegramIntents`. Unit/module tests only; not yet verified in a built app (combined build pending).
- **Follow-up (2026-11-03): attachments as files.** Videos, audio, GIFs and other files are loaded with `loadFileRepresentationForTypeIdentifier:` (the first registered type conforming to the wanted one, else that type itself, since a process does not always have the type database) and cloned inside the completion handler, where the system's file exists, into their own directory under a per-attempt directory `<root>/share/items/<uuid>` (`withShareItemFiles`, `ShareExtensionContext`). That directory is removed when the send completes, fails or is cancelled, and sessions older than a day are swept on the next send. On APFS the copy is a clone. Videos keep going through `LocalFileVideoMediaResource(path:)`; files and audio upload through `.tempFile` (a temp-box hard link, released when the upload ends), so the upload reads them piece by piece and nothing is copied into the media box; a GIF is mapped for the converter. Photos are downsampled straight from the system's file with `scaledJpegImageWithURL:` (the I-3 ImageIO helper), never copied or fully decoded. Whether a shared file is a photo or GIF is read from its header (`shareItemFileContent`), not by decoding it. A provider that cannot give a file falls back to the old loads (URL item copied while valid; in-memory data for `public.data`; UIImage for images). Text, URLs, contacts and passes are unchanged. I-10's limit of 3 at once, the 100-attachment cap, I-4's round-video check and I-7's HD size are unchanged. Tests: `ShareItemsTests` (`ShareItemFileRepresentationTests`: a 400 MB sparse file grows the test process's footprint by 32 KB; `ShareItemFilesLifetimeTests`, `ShareItemFileContentTests`). The stubs are data representations of generic types: a `registerFileRepresentation` stub cannot be loaded in a logic-test process (NSItemProvider's own copy fails there) and the type database is missing there, so only identical identifiers conform.
- **Follow-up (2026-11-03): share-to-story without the freeze.** `OpenResolvedUrl`'s `.shareStory` prepares its subjects off the main thread (photo decode, video move, then `SharedStorySession.videoMetadata`, which loads `duration`, the video track and its `naturalSize` with `load(_:)`/`loadTracks(withMediaType:)` on a detached task) and opens the editor on main. Values are those of the old synchronous reads (natural size without the transform; 0 s for an unreadable file), pinned by `SharedStoryVideoMetadataTests`, which also checks that the read finishes while the main thread is blocked. Not changed: the media editor's own synchronous `AVAsset` reads (`MediaEditorScreen`, `MediaEditorVideoExport`, `MediaEditorStoryCompletion`), which are shared by every story source.

- **Severity**: low. **Category**: modernization.
- **Evidence**: `TGItemProviderSignals.m` uses `loadItemForTypeIdentifier:` with implicit coercion throughout (`:140`,
  `:182`, `:276`, `:385`, `:449`, …), so NSData vs NSURL is not guaranteed. iOS 16-deprecated synchronous AVAsset
  access: `TGItemProviderSignals.m:310-320`, `:421`; `ShareItems.swift:115` (`CMTimeGetSeconds(asset.duration)`);
  `OpenResolvedUrl.swift:1304-1307`. Dead checks at the iOS 15 floor: `ShareExtensionContext.swift:298`, `:322`,
  `:861`; `TelegramIntents.swift:58`, `:217`, `:223`.
- **Effect**: blocking I/O on item-provider callback queues and fragile type assumptions (feeds the hang in I-2).
  **Corrected**: files are read with `NSDataReadingMappedIfSafe`, which is file-backed, so large files do not inflate
  the footprint.
- **Fix**: `loadFileRepresentation(forTypeIdentifier:)` / `loadInPlaceFileRepresentation` with `UTType` (the story
  path already uses `loadFileRepresentation`); `AVURLAsset.load(.tracks, .duration, .commonMetadata)` on iOS 16+ with
  `loadValuesAsynchronously` for 15; delete the dead branches. (Transferable, UIActivityItemsConfiguration and PHPicker
  are for sharing out or picking in, not for a share extension's receive side.)
- **Risk**: low; medium if the upload switches to file-backed resources.
- **How to verify**: build with deprecation warnings visible; share the same set of items (photo, video, file, URL,
  text) before and after and compare results.
- **Effort**: M. **Confidence**: high.

### I-12. Donors disagree on conversation identity; the share extension and AppDelegate read only `recipients.first`; notification donations bypass the suggestion settings — `done (dc13db12, f6ad1951)`

- **Implementation (2026-11-03)**: `SendMessageSuggestions` (NotificationsPresentationData) is the one identity (`tg<id>`, group `sendMessage_<id>`) and rule set. The notification extension reads `IntentsSettings` and passcode state with its other shared data and donates only what the app would (suggestions account, contacts/private chats/groups/Saved Messages, archive, bots, "only shared"), with the same conversation id and group identifier; the drawn intent keeps the bare id Siri replies use. Readers parse the conversation first, then each recipient. Whether iOS surfaces incoming-only donations was not checked on a device. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: medium. **Category**: bug. (Merges three reviewer findings across share, notifications and app.)
- **Evidence**: outgoing (`TelegramIntents.swift:180-205`): customIdentifier and conversationIdentifier =
  `"tg<chatPeerId>"`, `groupIdentifier = "sendMessage_<id>"`, filtered by passcode and IntentsSettings (`:58-75`:
  account, contacts, privateChats, groups, savedMessages, archived, bots). Incoming (NS HEAD `:626-660`, `:786-791`):
  `conversationIdentifier: "\(sender.peerId.toInt64())"` (no prefix), `recipients: [mePerson]` (customIdentifier nil),
  no `groupIdentifier`, no IntentsSettings read anywhere in the file, and it donates while a passcode is set (it only
  skips while locked). Readers: `ShareExtensionContext.swift:322-329` and AppDelegate HEAD `:2922` parse only
  `recipients?.first?.customIdentifier` with a `tg` prefix and ignore `intent.conversationIdentifier`. Per-chat removal
  `INInteraction.delete(with: "sendMessage_<id>")` (`TelegramIntents.swift:216-219`, `ContactsController.swift:668`)
  cannot match the NSE donations. Precedent: `SiriSendMessageTarget.swift:14-15` already parses a plain `<id>`.
  **Corrected**: the NSE uses the chat id, not the message author (`interactionAuthorId = peerId`, NS HEAD `:1368-1370`).
- **Effect**: the system sees one chat as "tg123" and "123". A suggestion built from incoming donations opens the
  extension with nothing preselected. Groups, non-contacts (privateChats defaults to false), archived chats and the
  other account's chats can come back after the user turned them off or chose one account, because the next push
  donates again. Removing one contact does not remove its notification donations. Whether iOS surfaces incoming-only
  conversations in the share sheet was not verified on a device.
- **Fix**: put the identifier mapping in one helper (`TelegramIntents` or next to `NotificationRecipientAccount`) with
  unit tests. Readers (share extension, AppDelegate) resolve from `intent.conversationIdentifier` first, accepting
  `tg<id>`, `<id>` and the account-qualified form from I-6, then fall back to recipients. Donors: the NSE reads
  `ApplicationSpecificSharedDataKeys.intentsSettings` in its existing sharedData read and applies the same rules
  before `interaction.donate` (the displayed intent from `content.updating(from:)` stays as is), and sets
  `groupIdentifier = "sendMessage_<peerId>"`. Coordinate with the NSE workflow.
- **Risk**: medium. Changing identifiers resets the system's learned ranking once; keep old forms parseable; recheck
  notification avatars and titles.
- **How to verify**: unit-test the helper and the gating rules. Device (release build): turn off Siri suggestions ▸
  Groups, receive a group message with the app suspended; the group does not reappear. Log `extensionContext.intent`
  in a TestFlight build to see which donor produced a tapped suggestion; tapping it opens that chat.
- **Effort**: M. **Confidence**: high on the mismatch and the bypass; medium on the share-sheet effect.

### I-13. Each send re-runs the whole donation pipeline, can donate twice with a blurry avatar, and keeps the fetch subscribed — `done (dc13db12)`

- **Implementation (2026-11-03)**: Each send still donates, but takes one complete avatar (`take(1)` after complete data, letters after 2 s), caches the encoded PNG `INImage` per peer and photo, and encodes and donates off the main queue. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low. **Category**: perf.
- **Evidence**: called on every send (`ChatController.swift:9240`, `ChatControllerLoadDisplayNode.swift:1142`,
  `ChatControllerMediaRecording.swift:764`, `ShareScreen.swift:470-474`). `peerAvatarImage` (`TelegramIntents.swift:143`)
  emits the blurred mini thumbnail and then the full avatar (`PeerAvatar.swift:43-60`); the result goes through
  `combineLatest` into an un-retained `.start` with JPEG encoding and `INInteraction.donate` on the main queue
  (`TelegramIntents.swift:157-200`), so every emission re-donates. The fetch lives until it completes.
- **Effect**: per send: DB reads, an avatar decode and render, a main-thread JPEG encode and an XPC donation; two
  donations (the first blurry) when the avatar is not cached; small leaks for avatars that never finish.
- **Fix**: keep donating on each send, but cache the encoded `INImage` per (peerId, photo resource id); take only the
  final avatar (`take(1)` after complete data, or a placeholder after ~2 s); encode off main as PNG; retain the
  disposable.
- **Risk**: low.
- **How to verify**: log in the donate closure; 5 sends to a chat with an undownloaded avatar give 10 donations today,
  5 after; no main-thread JPEG work in Time Profiler.
- **Effort**: S. **Confidence**: high.

---

## Notifications (NotificationService, NotificationContent, app-side delegate)

### I-14. Story notifications download the whole story video into memory — `done (f6ad1951)`

- **Implementation (2026-11-03)**: A video story is prefetched only up to its preload size (none without one), with the file size passed, and each part is written into MediaBox by range as it arrives (no `Data` accumulation, never a prefix stored as the whole file); the timeout is `min(10, remaining budget)`. Jetsam rate not measured. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: high. **Category**: memory.
- **Evidence**: NS HEAD `:2398-2433`: `fetchSize = preloadSize.flatMap(Int64.init)` is discarded at `:2440`
  (`guard let (resource, _) = resourceData`), and `:2444` requests `0 ..< Int64.max`. The buffer is
  `Atomic<Data>`; `modify` hands the closure a copy (`SwiftSignalKit Atomic.swift:40-46`), so every append copies the
  whole buffer (O(n²) memcpy, 2× peak). `size: nil` with a story reference gives serial 512 KB parts
  (`MultipartFetch.swift:575-580`). Fixed `timeout(10.0)` at NS HEAD `:2564`, ignoring `remainingBudget()`. The result
  is stored only if the download finishes. `MediaBox.storeResourceData(_:range:data:)` exists (`MediaBox.swift:333`).
- **Effect**: a story video of several to tens of MB can push the extension past its memory limit (~24 MB) on Wi-Fi,
  so iOS kills it. The notification falls back to the server's plain alert (no avatar, no badge, no "displayed"
  marker), and the download is lost. On cellular it spends data on full videos only to prefetch them. Kill frequency
  not measured.
- **Fix**: fetch only `0 ..< preloadSize` for video stories (or skip video prefetch); pass `size: file.size`; write
  each part into MediaBox by range instead of accumulating `Data`, never storing a prefix as the complete file; at
  minimum use the message path's offset-aware `final class DataValue`; timeout `min(10, remainingBudget())`.
- **Risk**: low. The app's story preloading reads partial ranges anyway.
- **How to verify**: app suspended, Wi-Fi, a second account posts a 30-60 s video story. Watch Console.app for the
  NotificationService jetsam / EXC_RESOURCE, or Allocations on the extension. After the fix, footprint stays under
  ~15 MB and notification-logs show "Updating content".
- **Effort**: M. **Confidence**: high on the code; medium on how often the kill happens.

### I-15. Every notification download passes `size: nil`, so it runs as one 128 KB part at a time — `partial (f6ad1951)`

- **Implementation (2026-11-03)**: Message media and custom-emoji downloads pass the resource size (parallel parts, offset-aware buffer sized to it); video stickers are no longer fetched. The notification-sound downloads keep `size: nil`: they append parts in order, which parallel parts would corrupt, and sounds are small. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low (**Corrected** from medium). **Category**: perf.
- **Evidence**: `standaloneMultipartFetch(… size: nil, …)` at NS HEAD `:1764` and the other fetch sites (custom emoji,
  sound, story, reactions). `MultipartFetch.swift:589-592`: `size == nil` → `parallelParts = 1`,
  `defaultPartSize = 128 * 1024`; a known size gives 8×512 KB or 16×16 KB (`:581-588`). The size is available on the
  resource. A timeout discards the partial download (it lives in `Data`, not MediaBox). Video stickers are fetched
  (NS HEAD `:1732`) but only static and animated stickers are attached (`:2111-2135`).
- **Effect**: **Corrected**: the usual largest photo ("y", 1280 px, ~100-300 KB) is 1-3 round trips, so the gain is
  mainly for HD "w" photos and slow links or proxies, where the 10 s budget can run out and the notification loses
  its picture. Video-sticker downloads are wasted.
- **Fix**: pass `size: resource.size` everywhere; when `remainingBudget()` is short, pick a smaller size; write parts
  into MediaBox by range; skip video stickers (or render their first frame).
- **Risk**: low.
- **How to verify**: Network Link Conditioner 3G, Log to File on; compare "Will fetch media" → "Did fetch media" times
  in notification-logs, and count photo notifications that arrive with the image.
- **Effort**: S. **Confidence**: high on the serial fallback; the latency gain is an estimate.

### I-16. Custom-emoji rendering uses `try!` and a private KVC key — `done (f6ad1951)`

- **Implementation (2026-11-03)**: `notificationEmojiGlyph` crops to a square with a tile no larger than the image and returns nil instead of trapping; `attributedBody` is set only when the content responds to `setAttributedBody:`. Test: `NotificationEmojiGlyphTests`. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low (**Corrected** from medium). **Category**: bug.
- **Evidence**: NS HEAD `:740`: `let glyph = try! Customoji.makeGlyph(from: image, …, tileSizes: [40], cropToSquare: false)`;
  `makeGlyph` throws for non-square, under-40 px, or HEIC finalize failure (`:3428-3461`). `:745`:
  `content.setValue(attributedString, forKey: "attributedBody")`.
- **Effect**: **Corrected**: the inputs that trap are rare. The Lottie path renders exactly 40×40 (`:290-296`) and
  static custom-emoji WebP are platform-required 100×100. The real risks are an odd emoji asset or a future iOS that
  renames the private key; either crashes the extension and the user gets the server's plain alert.
- **Fix**: `guard let glyph = try? …` with a plain-text fallback, `cropToSquare: true`, tile clamped to the side; set
  `attributedBody` only if `content.responds(to: NSSelectorFromString("setAttributedBody:"))`.
- **Risk**: very low.
- **How to verify**: unit-test the helper with 100×80 and 32×32 images: nil, no trap. Device: a message with a static
  custom emoji still renders the glyph.
- **Effort**: S. **Confidence**: high on the trap; low on frequency.

### I-17. The Notification Content extension never runs — `done (f6ad1951)`

- **Implementation (2026-11-03)**: The extension target, its plist, link/lib targets, the framework-export client entries, `Telegram/NotificationContent` and `NotificationContentContext.swift` are removed. Signing helpers (`BuildConfiguration.py`, `device_signing.py`, `verify.sh`) still know the profile name; an unused profile is harmless, and the App ID can be deleted in the portal later. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low. **Category**: perf.
- **Evidence**: `Telegram/BUILD:1214-1218` declares `UNNotificationExtensionCategory` = `withReplyMedia`,
  `withMuteMedia`; nothing sets them (registered categories are r/m/gr/gm/c/t/st/str, AppDelegate HEAD `:3327-3335`).
  `NotificationContentContext.swift:155-173` also requires `Int64`/`Int32` userInfo keys nothing writes. The extension
  is still embedded (`Telegram/BUILD:2009`), links TelegramUIFramework, and would build a full SharedAccountContext
  after a main-thread semaphore wait (`:100-146`).
- **Effect**: no user-visible behaviour. Cost: an extra .appex, App ID and profile, a TelegramUIFramework client and
  build time; if ever wired up, a heavy context in a memory-limited extension that shows nothing.
- **Fix**: remove the target (extensions list, NotificationContentInfoPlist, NotificationContentExtensionLib,
  `Telegram/NotificationContent`, its framework-exports client entry, the profile). Write a light preview later if
  wanted.
- **Risk**: low. Check that `tg device` / `tg testflight` and signing do not expect the NotificationContent profile.
- **How to verify**: build, compare `unzip -l` of the IPA; long-press photo, sticker and voice notifications before and
  after: identical.
- **Effort**: S. **Confidence**: high.

### I-18. Group notifications present the chat as the sender; the iOS 15 group conversation style is unused — `dropped (needs device measurement)`

- **Implementation (2026-11-03)**: Changes the look of every group notification and interacts with the measured recipient-account naming (`NotificationNames`, iOS 18.6/27); it should be done with a device in hand, not blind.

- **Severity**: low. **Category**: modernization.
- **Evidence**: NS HEAD `:1370` `interactionAuthorId = peerId` (the group for chat pushes); `addSenderInfo` uses that
  peer (`:2276`). `speakableGroupName` is the sender name for 1:1 chats too (`:786`), with `recipients: [mePerson]`.
  The real author is loaded after the poll (`message.author`).
- **Effect**: group notifications show the group avatar as a person; no author face with a group badge; Focus
  allowed-people and contact matching cannot see the author; Siri treats each group as a person.
- **Fix**: after the poll, for groups: sender = message author, `speakableGroupName` = chat title, recipients = [me +
  one other], `intent.setImage(groupAvatar, forParameterNamed: \.speakableGroupName)`; for 1:1 chats,
  `speakableGroupName = nil`. Keep `conversationIdentifier` as the chat. Preserve the recipient-account naming
  invariant in `NotificationNames` (CLAUDE.md) and re-measure on iOS 18 and 27.
- **Risk**: medium. Changes group notification looks and Siri reply targets.
- **How to verify**: iOS 18 and 27 devices: author photo with group badge and group title; a Focus allowing only that
  author lets it through; Siri Announce reply goes to the group.
- **Effort**: M. **Confidence**: high on the code; the visual result needs a device.

### I-19. Silent messages still wake the screen; `interruptionLevel` and `relevanceScore` unused for messages — `done (f6ad1951)`

- **Implementation (2026-11-03)**: A silent message gets `interruptionLevel = .passive`. `relevanceScore` not added (benefit speculative). Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low. **Category**: modernization.
- **Evidence**: NS HEAD `:1417-1419`: payload `silent` only sets `content.silent`, which adds a " 🔕" suffix. No
  `interruptionLevel`/`relevanceScore` for messages; `.passive` is used only in `ServicePushPresentation.swift:52`.
- **Effect**: a message the sender sent silently still lights the lock screen.
- **Fix**: `content.interruptionLevel = .passive` when silent. Optional: `relevanceScore` for mentions and replies
  (Summary benefit is speculative).
- **Risk**: low.
- **How to verify**: send a silent message from a second account to the locked device: the screen stays dark and the
  notification is in Notification Center.
- **Effort**: S. **Confidence**: high on the code.

### I-20. Avatar cache disabled, letters cache keyed without the peer, wrong temp path — `done (f6ad1951)`

- **Implementation (2026-11-03)**: The rendered avatar cache is used again under a versioned key (`intents-v3`); the letters key carries the gradient index; temp copies go to `aps-data/<hash>.png`; the avatar helpers use `UIGraphicsImageRenderer` (sRGB). Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low. **Category**: perf.
- **Evidence**: NS HEAD `:472` `if let _ = fileSize(cachedPath), !"".isEmpty {` (always false), so every notification
  decodes, renders, PNG-encodes and atomically writes the avatar into the shared container. `:490`
  `"lettersAvatar2-\(letters…)"` while the gradient depends on peerId (`:387-393`); the fork's callerAvatar uses it
  too (`:511`). `:455-458`: `NSTemporaryDirectory() + "/aps-data"` + `"\(hash).jpg"` has no separator and holds PNG
  bytes. `storeTemporaryImage` returns an existing temp file by path hash, so a wrong letters colour sticks until tmp
  is purged. `UIGraphicsBeginImageContextWithOptions` (`:300/:316/:375`) is deprecated.
- **Effect**: avoidable CPU and a shared-container write on every push; letter avatars can show another chat's colour.
- **Fix**: restore the cache check with a versioned key; add peerId/colour index to the letters key; fix the separator
  and use `.png`; switch to `UIGraphicsImageRenderer`.
- **Risk**: very low.
- **How to verify**: two messages from one contact: the cache file's mtime does not change on the second; two chats
  with the same initials show different gradients.
- **Effort**: S. **Confidence**: high on the code; low on measurable impact.

### I-21. Decrypted message text is written to notification logs without redaction — `done (f6ad1951)`

- **Implementation (2026-11-03)**: With redaction on (the default) the log keeps only the payload's keys and `loc_key`, text lengths instead of titles and bodies, and userInfo keys. Tests: `NotificationLogRedactionTests`. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low. **Category**: bug.
- **Evidence**: NS HEAD `:1151` `"Decrypted payload: \(payloadJson)"`; `"Updating content to \(content)"` (title, body,
  userInfo) at `:2173`, `:2592` and others. `redactSensitiveData` is not honoured. **Corrected**: `Logger.log` takes an
  autoclosure and returns early when logging is off (`Log.swift:333-336`), so there is no cost or leak unless Log to
  File is on (default only in internal builds, NS HEAD `:937-939`).
- **Effect**: with Log to File on, message text and names land in `logs/notification-logs`, which Debug ▸ send logs
  exports.
- **Fix**: log only loc-key, ids and flags, or the payload only when `!Logger.shared.redactSensitiveData`.
- **Risk**: none.
- **How to verify**: Log to File on, receive a message, grep notification-logs for its text.
- **Effort**: S. **Confidence**: high.

### I-22. `willPresent` sometimes never calls its completion handler; deprecated badge API — `done (dc13db12, f6ad1951)`

- **Implementation (2026-11-03)**: `willPresent` takes one account id and always calls the handler (`[]` when the app shows it in-app; `ForegroundNotificationPresentation`, tested). The badge uses `setBadgeCount` on iOS 16+. Unit/module tests only; not yet verified in a built app (combined build pending).

- **Severity**: low. **Category**: bug.
- **Evidence**: AppDelegate HEAD `:3361-3370` calls `completionHandler([.banner, .list])` only when the notification's
  account differs from the current one, or for a URL notification; other branches never call it. AppDelegate HEAD
  `:2072`: `UIApplication.shared.applicationIconBadgeNumber = Int(count)` (deprecated in iOS 17).
- **Effect**: Apple requires the handler to be called; the block leaks and behaviour relies on a system timeout. The
  badge setter warns under the iOS 27 SDK and may stop working.
- **Fix**: `completionHandler([])` in every other branch; `UNUserNotificationCenter.current().setBadgeCount(_:)` under
  `#available(iOS 16, *)`, old setter below.
- **Risk**: very low.
- **How to verify**: log in `willPresent` with a notification for the current account in the foreground; the badge
  still updates when chats are read on iOS 15 and 27 simulators.
- **Effort**: S. **Confidence**: high.

---

## Intents / Widgets / Shortcuts / Spotlight

### I-23. Home-screen widgets show message text and unread counts while the app is passcode-locked — `done (2ae677a3)`

- **Status**: widgets read the lock state (`appLockSchedule`, AppLockStateTests); locked rows keep name and photo and show "Locked" with no badge; a timeline drawn while unlocked carries a second, hidden entry at the auto-lock deadline; WidgetDataContext reloads on lock/unlock. Not yet verified in a built app.

- **Severity**: high (verifier: defensible, arguably medium). **Category**: bug.
- **Evidence**: `Telegram/WidgetKitWidget/TodayViewController.swift:68-218` (`getCommonTimeline`) builds
  `WidgetDataPeer.Message` and `badge` without reading `appLockStatePath`/`isAppLocked`, while the Intents side refuses
  when locked (`IntentHandler.swift:343`, `:893`). `submodules/TelegramUI/Sources/WidgetDataContext.swift:99` takes
  `appLockContext` and never uses it.
- **Effect**: with the app passcode on and the app locked, anyone holding the unlocked phone reads the last message
  and unread count of every chat in the Chats widget. Notifications already hide content in this state.
- **Fix**: in `getCommonTimeline`, read the lock state as the intent handler does; when locked, keep names and avatars
  but replace the message line with the locked text and drop the badge. In WidgetDataContext, subscribe to the lock
  state and `reloadAllTimelines` on change. **Corrected**: the views call `.unredacted()` (`TodayViewController.swift:734`,
  `:848`), so `.privacySensitive()` only helps if that modifier is removed or made conditional.
- **Risk**: low. Keep the unlocked output identical.
- **How to verify**: Chats widget with 2 chats, enable a passcode, lock the app, go home: text hidden; unlock: text
  back within one reload. Unit test a pure (peers, isLocked) → entry helper.
- **Effort**: S. **Confidence**: high.

### I-24. Siri replies and donated "Message X" shortcuts fail without Contacts access, and the app's `tg<id>` donations are not parsed — `done (268c99ed)`

- **Status**: Contacts gate only where address-book people are resolved (`siriSendMessageNeedsContacts`); `tg<id>` conversation identifiers parsed; `tg` persons pass `resolve(persons:)` (`siriPersonIsResolvable`). IntentsExtensionTests. Not yet verified on a device.

- **Severity**: medium. **Category**: bug.
- **Evidence**: `Telegram/SiriIntents/IntentHandler.swift:538` (resolveContent) and `:560` (confirm) require
  `CNContactStore.authorizationStatus(for: .contacts) == .authorized` first, even when `conversationIdentifier` names
  the chat (resolveRecipients at `:484` does not need Contacts there). The app donates `"tg<id>"`
  (`TelegramIntents.swift:201`), but `:484` and `SiriSendMessageTarget.swift:15` parse only a bare `Int64`; the
  fallback `resolve(persons:)` (`:355-369`) keeps only persons with a `contactIdentifier`, and the donated person has
  none (`TelegramIntents.swift:199`), so the result is `.unsupported`.
- **Effect**: with Contacts denied, a dictated reply to an announced message is dropped with "continue in app". A
  donated "Send message to <chat>" Siri or Shortcuts suggestion is rejected even with Contacts granted. **Corrected**:
  share-sheet suggestions are not affected (they open the Share extension, not this handler).
- **Fix**: gate on Contacts only where address-book people are resolved; skip the check in resolveContent and confirm
  when `siriSendMessageTarget(...)` yields a peer; make it and `:484` accept the `tg` prefix (shared helper from I-12);
  let `tg`-prefixed persons through `resolve(persons:)` without a contactIdentifier.
- **Risk**: low to medium. Acceptance still goes through `siriRecipientDecision`/`peerAcceptsSiriMessages`; keep the
  lock-state early returns first.
- **How to verify**: SiriIntentsTests: `siriSendMessageTarget("tg123", nil) == 123`, and a resolveContent/confirm case
  with conversationIdentifier set and Contacts denied. Device: deny Contacts, Announce Notifications, "reply hello";
  run a donated Send Message suggestion from Shortcuts.
- **Effort**: S. **Confidence**: high on the code path; medium on Siri's exact call order for donated shortcuts.

### I-25. Calling back from Phone Recents mis-decodes 64-bit user ids and always starts an audio call — `done (d1de38a0)`

- **Status**: CXHandle, incoming handles and donated INPerson are `nanogram-call:<accountId>:<packed peer>` (`CallKitHandle`, TelegramCallsUITests); raw and `tg` forms still parsed as users; real call capability donated and called back; `SupportedStartVideoCallIntent` removed. The NSE path was 806ff160/9363a551. Not yet verified in a built app.

- **Severity**: medium. **Category**: bug.
- **Evidence**: handles are written as the raw id with no namespace: `CallKitIntegration.swift:99-100`
  (`INPersonHandle(value: "tg\(peerId.id._internalGetInt64Value())")`), `:227` (`CXHandle(type: .generic, value: "\(…_internalGetInt64Value())")`),
  `PresentationCall.swift:766`, AppDelegate `:2508`/`:2631`. They are read back as a packed id: AppDelegate
  `:2873-2883` → `PeerId(value)`; `Postbox/Peer.swift:148-170` takes bits 32-34 as the namespace, so ids ≥ 2^32 decode
  as CloudGroup with a truncated id. `IntentHandler.personWithPeer` uses the packed `"tg\(toInt64())"`, so two
  encodings already coexist. Video: AppDelegate `:2823-2828` checks `SupportedStartVideoCallIntent` (`:193`), which
  nothing conforms to; the donated intent hard-codes `callCapability: .audioCall` (`CallKitIntegration.swift:102`).
  Since review, `806ff160` added a separate path for calls the NSE rang: an account-qualified, packed
  `IncomingCallNotifications.callBackIdentifier` (`nanogram-call:<accountId>:<peerId>`) handled first in
  `handleUserActivity`, with video from `callCapability`. CallKit Recents handles and the app's own donations still
  use the raw form.
- **Effect**: tapping a Nanogram call in Phone ▸ Recents, or a Siri call suggestion, for a non-contact with a modern
  64-bit id resolves to a non-existent group and the call silently does not start. A video call is called back as
  voice.
- **Fix**: write `nanogram-call:<accountId>:<packedPeerId>` (or at least `peerId.toInt64()`) in CXHandle, the donated
  INPerson and incoming handles; parse all three forms (new, packed, raw → retry as
  `PeerId(namespace: CloudUser, id: ._internalFromInt64Value(raw))` when the packed decode is not a user). Donate the
  real `callCapability`. Delete `SupportedStartVideoCallIntent`. Do not change `CallSessionManager.getStableIncomingUUID`.
- **Risk**: medium. Existing Recents entries keep the raw form, so the parser must keep accepting it.
- **How to verify**: unit test a user id 6_000_000_000 round-trip through writer and parser. Device: call with a
  non-contact whose id > 2^32, tap it in Recents; call back a video call and it starts as video.
- **Effort**: S. **Confidence**: high on the decoding mismatch; medium on how many users are affected.

### I-26. Extensions can still trap when the account-manager databases cannot be opened — `partial (6a3af308, 268c99ed, d5e15bcc)`

- **Status**: `AccountManager.openForExtension` / `setupExtensionAccountManager` return nil instead of trapping (non-owner SqliteValueBox open failures return nil; PostboxTests, TelegramCoreTests); Siri adopts it; message, call and search intents restricted while protected data is unavailable. Left: the Share extension, NotificationService and NotificationContent still call `setupAccountManager` (files owned by the share/notification work); switching them is a one-line change each.

- **Severity**: medium (**Corrected**: frequency unproven, but it hits every extension). **Category**: bug.
- **Evidence**: `submodules/TelegramCore/Sources/AccountManager/AccountManagerImpl.swift` (**Corrected** path):
  `preconditionFailure()` at `:148` (guard_db nil), `:168` (db nil after 3 retries with sleeps), `:813` (init nil).
  `SqliteValueBox.swift:904-910` returns nil for non-owners on lock contention, I/O errors or data-protection EPERM.
  `IntentHandler.swift:173` opens the manager per intent with `removeDatabaseOnError: false`. `Telegram/BUILD:1439-1442`
  has `IntentsRestrictedWhileLocked` and `IntentsRestrictedWhileProtectedDataUnavailable` empty. The recent fixes
  (`afac00d5`, `587800e6`) covered getCurrentRecords and the atomic-state fallback, not the SQLite open.
- **Effect**: a Siri request, share or notification that coincides with the app holding accounts-metadata, or with
  protected data unavailable, crashes the extension (SIGTRAP) instead of answering "open Nanogram".
- **Fix**: add a failable extension open (`AccountManager.tryOpen(...) -> AccountManager?`), reachable only with
  `removeDatabaseOnError == false`; Siri handlers already complete with failureRequiringAppLaunch when the account is
  nil, the share extension shows I-5's alert, the NSE falls back to the plain alert. Add the message, call and search
  intents to `IntentsRestrictedWhileProtectedDataUnavailable`.
- **Risk**: low for extensions; the app keeps its crash-and-relaunch policy.
- **How to verify**: extend the AccountManagerExtensionReadOnlyTests pattern: make guard_db mode 0000 and assert an
  extension-mode open returns nil. Device: hold a lock on `accounts-metadata/db` from a debug hook and ask Siri to
  read messages; expect "open app" and no crash report.
- **Effort**: M. **Confidence**: high that the traps exist; low-medium on frequency.

### I-27. Widget refresh is not coalesced and each timeline asks to be refreshed at once — `partial (2ae677a3)`

- **Status**: foreground reloads debounced 3 s and at least 15 s apart; timelines use `.after(now + 30 min)`. Not done: `reloadTimelines(ofKind:)` (both widgets read the same chats, so both reload).

- **Severity**: low (**Corrected**). **Category**: perf.
- **Evidence**: `WidgetDataContext.swift:57-61` → `performReloadIfNeeded()` with no debounce; `:85`
  `WidgetCenter.shared.reloadAllTimelines()` (both kinds), fired at `:268-270` on each distinct top-message list for
  widget chats. `TodayViewController.swift:215` returns one entry dated now with `policy: .atEnd`. Each timeline opens
  every configured account's encrypted Postbox.
- **Effect**: extra widget-extension launches and SQLCipher opens on busy chats in the foreground, and background
  reloads drawn from the daily budget. **Corrected**: WidgetKit spaces and budgets refreshes, so the reviewer's "1-2
  launches/s" is not shown; treat the cost as an estimate until measured.
- **Fix**: debounce foreground reloads (3-5 s trailing, at most one per 15 s); reload only the affected kind
  (`reloadTimelines(ofKind:)`); return `.after(Date() + 30*60)` instead of `.atEnd`, since the app pushes reloads.
- **Risk**: low; the widget may lag by the debounce.
- **How to verify**: os_signpost in `getCommonTimeline`; count extension launches while 30 messages arrive in a widget
  chat, before and after; `log stream --predicate 'subsystem == "com.apple.chrono"'`.
- **Effort**: S. **Confidence**: high on the code; medium on the cost.

### I-28. Widget configuration polling still runs every 60 s in the background — `done (2ae677a3)`

- **Status**: the 60 s tick runs only in the foreground.

- **Severity**: low. **Category**: perf.
- **Evidence**: `WidgetDataContext.swift:163-176` (fork `9bc6231a`): the comment says the 60 s poll replaced a
  background 10 s poll, but `periodicTick` is combined with `inForeground` (`:173-176`) and never gated by it, so
  `WidgetCenter.shared.getCurrentConfigurations` keeps running in the background, and with no widgets installed.
- **Effect**: ~60 extra XPC calls and wake-ups per hour while the process lives in the background (audio, VoIP); the
  comment misleads.
- **Fix**: `inForeground |> distinctUntilChanged |> mapToSignal { $0 ? periodicTick : .single(()) }`.
- **Risk**: very low.
- **How to verify**: log in `currentAdditionalPeerIds`; 5 minutes in the background with audio: 0-1 calls (~5 today).
- **Effort**: S. **Confidence**: high.

### I-29. Extension bootstrap re-runs for every intent and every widget timeline — `done (268c99ed, 2ae677a3)`

- **Status**: `SiriExtensionEnvironment` (one TempBox, logger, key read and account manager per Siri process) and `WidgetExtensionEnvironment` (once per widget process); account records are still read per handler.

- **Severity**: low. **Category**: perf.
- **Evidence**: `IntentHandler.handler(for:)` builds a new handler per intent (`:105-116`); each init repeats
  `performAppGroupUpgrades`, `TempBox.initializeShared(…, launchSpecificId: random)`, encryption-parameter reads and,
  for Siri, `setupAccountManager` (`:159`, `:163`, `:173`, `:999`, `:1003`). `TempBox.swift:156-179` replaces the global
  and deletes other `temp-*` dirs of that process type. The widget repeats `EngineTempBox.initializeShared` and
  `try! PasscodeEnvironment.shared.configure` per timeline (`TodayViewController.swift:85`, `:95`).
- **Effect**: repeated SQLite opens, key-file reads and directory scans per Siri request and widget refresh.
  **Corrected**: temp files vanishing under a cached Account, and a data race on the TempBox global, are plausible but
  not shown.
- **Fix**: one process-wide `static let` bootstrap per extension (rootPath, encryption params, TempBox, logger, and a
  shared AccountManager for Siri); keep re-reading account records per handler.
- **Risk**: low.
- **How to verify**: signpost handler init; three Siri requests in a row produce one TempBox dir and one
  AccountManager open.
- **Effort**: S. **Confidence**: medium.

### I-30. The Intents extension declares the deprecated `INStartAudioCallIntent` — `done (d5e15bcc)`

- **Status**: `IntentsSupported` declares `INStartCallIntent`; MARK fixed (268c99ed). Needs the device check in the spec.

- **Severity**: low. **Category**: modernization.
- **Evidence**: `Telegram/BUILD:1446` `IntentsSupported` lists `INStartAudioCallIntent` and not `INStartCallIntent`;
  `DefaultIntentHandler` conforms only to `INStartCallIntentHandling` (`IntentHandler.swift:116`; stale MARK at `:822`).
  Upstream ships the same plist.
- **Effect**: "Hey Siri, call X on Nanogram" depends on undocumented mapping from the legacy declaration; video calls
  via Siri are not declared. The failure itself is not shown.
- **Fix**: replace with `INStartCallIntent`; fix the MARK comment.
- **Risk**: low.
- **How to verify**: device: "Hey Siri, call <contact> using Nanogram" and a video variant; the extension logs
  `handle(INStartCallIntent)` and the call starts.
- **Effort**: S. **Confidence**: low (needs a device check).

### I-31. No App Intents adoption: legacy SiriKit widget configuration; no App Shortcuts, small/lock-screen/StandBy widgets, controls or interactive rows — `partial (2ae677a3, 268c99ed)`

- **Status**: only the cleanup: dead iOS 14 widget configuration branches and the iOS 10 `resolveRecipients` overload removed. App Intents phases 1-3 (ChatEntity/App Shortcuts, AppIntentConfiguration migration, ControlWidget) not started: L effort and needs the App Intents metadata processor in Bazel; deferred.

- **Severity**: medium (**Corrected**: a gap, not a defect). **Category**: modernization.
- **Evidence**: `TodayViewController.swift:884`/`:910` `IntentConfiguration(kind:, intent: SelectFriendsIntent.self, …)`
  (options from the separate Intents extension); `.supportedFamilies([.systemMedium])` only, so the `.systemSmall`
  branches (`:302`, `:765`) are dead. No `import AppIntents`, `AppShortcutsProvider`, `AppIntentConfiguration`,
  `ControlWidget` or `isEligibleForPrediction` anywhere. Dead `#available(iOS 15)` branches (`:883-898`, `:909-924`);
  the iOS 11 `resolveRecipients` overload (`IntentHandler.swift:464`).
- **Effect**: configuring a widget launches a second extension that opens every account's Postbox. Nanogram has no
  App Shortcuts in Shortcuts or Spotlight, no Lock Screen/StandBy/small widgets, no Control Center control, no
  in-widget mark-as-read.
- **Fix**: phase 1 (iOS 16+): an AppIntents module with `ChatEntity` + EntityQuery reading the app-group Postbox
  read-only, `OpenChatIntent`/`SendMessageIntent`, and an AppShortcutsProvider. Phase 2 (iOS 17+): both widgets on
  `AppIntentConfiguration` with a `WidgetConfigurationIntent` whose chat ids match SelectFriendsIntent
  (`accountId:peerId`), migrated via `CustomIntentMigratedAppIntent`; `.systemSmall`, `.accessoryCircular`, a
  mark-read `Button(intent:)`; keep IntentConfiguration for 15-16. Phase 3 (iOS 18+): a ControlWidget. Remove the dead
  branches and the iOS 11 overload.
- **Risk**: medium. Widget migration must keep users' setups; the App Intents metadata processor must run in Bazel.
- **How to verify**: existing widgets keep their chats after update; Shortcuts lists Nanogram App Shortcuts; the
  gallery offers the new families; unit-test the EntityQuery on a fixture Postbox.
- **Effort**: L. **Confidence**: high on the gap; effort is an estimate.

### I-32. Spotlight: contacts stay indexed while a passcode is set; generic item type, random version, file-URL thumbnail — `done (a20126b2)`

- **Status**: index emptied while a passcode is set; `UTType.contact`, displayName, @username alternate names, `thumbnailData`, content-derived version, stored item = indexed item, print removed. Not yet verified in a built app.

- **Severity**: low. **Category**: bug. (Merges the Spotlight modernization and passcode findings.)
- **Evidence**: `SharedAccountContext.swift:1094-1110` gates Spotlight only on `intentsSettings.contacts`; enabling a
  passcode calls only `deleteAllSendMessageIntents()` (`PasscodeOptionsController.swift:783`). In
  `submodules/TelegramUI/Sources/SpotlightContacts.swift`: `:152` `CSSearchableItemAttributeSet(itemContentType: UTType.text.identifier)`
  with only `title`; `:153` random `version`; `:161` `thumbnailURL` into the app group; `:170`
  `self.items[peerId] = item` stores the unnormalised item; `:119` prints contact names.
- **Effect**: with the app passcode on, anyone with the unlocked phone finds Nanogram contacts with photos in system
  search, unlike share suggestions. Results look like generic text, @username is not searchable, and the random
  version defeats change detection.
- **Fix**: add the access-challenge state to the `enableSpotlight` signal (no accounts → the domain is deleted). Use
  `UTType.contact` with `displayName`, `alternateNames` (@username), `thumbnailData` instead of `thumbnailURL`, a
  version derived from the item; store `encodeItem` in `self.items`; remove the print. **Corrected**: a late avatar
  download is picked up only at the next contacts-list emission even after the `self.items` fix.
- **Risk**: low; one reindex on upgrade.
- **How to verify**: enable a passcode, search a contact name in Spotlight: gone; disable: back. Search an @username
  and check the person layout and avatar.
- **Effort**: S. **Confidence**: high on the code; whether Spotlight can read the app-group thumbnail URL is unverified.

### I-33. A newly added Chats widget and its snapshot are empty — `done (268c99ed, 2ae677a3)`

- **Status**: `defaultFriends(for: SelectFriendsIntent)` (2 recent chats, 1 s bound); non-preview snapshots use the timeline's first entry.

- **Severity**: low. **Category**: bug.
- **Evidence**: `TodayViewController.swift:228`, `:246`: getSnapshot returns empty peers when `!context.isPreview`;
  nil `friends` gives empty peers (`:108`). `FriendsIntentHandler` (`IntentHandler.swift:1217-1230`) has no
  `defaultFriends(for:)`, while `AvatarsIntentHandler` does (`:1251`).
- **Effect**: after adding the Chats widget the user sees "Long tap to edit" until configuring it by hand.
- **Fix**: implement `defaultFriends(for: SelectFriendsIntent)` reusing `WidgetIntentHandler.defaultFriends()` (top 2
  recent peers, bounded by ~1 s); in non-preview getSnapshot, use the first `getCommonTimeline` entry.
- **Risk**: low.
- **How to verify**: add a new Chats widget: the two most recent chats show without editing.
- **Effort**: S. **Confidence**: high.

---

## Other integrations (URL schemes, files, pasteboard, drag and drop, screen sharing, location, photos, plist)

### I-34. A tg:// link that cold-launches the app while logged out is never handled, and retapping it is ignored — `done (84ed6c28)`

- **Status**: launch URLs go through `handleOpenURL`/`openUrl`; the de-dup flag always clears after 1 s; dead `launchOptions[.url]` branch removed. Not yet verified in a built app.

- **Severity**: medium (**Corrected** from high). **Category**: bug.
- **Evidence**: AppDelegate HEAD `:1837-1840` (`attach`, cold launch) routes tg/ton/app-scheme URLs to
  `openUrlWhenReady` (`:3128`), which sets `openUrlInProgress` and waits on `authorizedContext() |> take(1)`; that
  completes at once while logged out (`:2738-2746`). Only `openUrl` (`:2761-2800`) handles the auth-screen case
  (`parseConfirmationCodeUrl`, `parseProxyUrl` incl. webproxy). Retaps are dropped by
  `guard self.openUrlInProgress != url` (`:2750`) until a post-auth delay clears it (`:3166`), and after a later login
  the stale URL opens. The `launchOptions[.url]` branch (`:1624-1629`) is dead under the scene lifecycle.
- **Effect**: on a logged-out device with the app not running, a tg://proxy, socks, webproxy or login-code link opens
  the auth screen with no proxy sheet, and tapping it again does nothing. These are exactly the users who need a proxy
  to log in. With the app running, the same link works.
- **Fix**: send every launch URL in `attach` through `handleOpenURL`/`openUrl` (it waits on authorized or auth context
  and handles ton/TonConnect in the authorized branch), or make `openUrlWhenReady` wait on
  `combineLatest(context, authContext)`. Set `openUrlInProgress` only once dispatched (or clear on timeout). Delete the
  dead `launchOptions` branch.
- **Risk**: low. Check the 1 s de-dup still prevents a double open.
- **How to verify**: simulator signed out, app terminated: `xcrun simctl openurl booted 'tg://socks?server=1.2.3.4&port=1080'`.
  Today nothing; after, the proxy sheet on the auth screen. Repeat with webproxy and with the app running.
- **Effort**: S. **Confidence**: high.

### I-35. Picked iCloud/Files documents leak security-scoped access grants — `done (f3325f34)`

- **Status**: scoped access stopped on every exit of the description, after the thumbnail and on coordination errors; the copy item keeps its deinit.

- **Severity**: low (**Corrected** from medium). **Category**: memory.
- **Evidence**: `submodules/ICloudResources/Sources/ICloudResources.swift:301` starts access; the thumbnail branch
  (`:311-323`) never stops it (only `ICloudFileResourceCopyItem.deinit`, `:262`, does, on the copy path); the
  NSFileCoordinator error branch (`:343-344`) does not stop it, and the stops at `:332`/`:341` are commented out.
  `descriptionWithUrl` returns early without stopping at `:130`, `:134`, `:139` (it stops only at `:188`). The picker
  opens scoped URLs (`LegacyICloudFilePicker:88`).
- **Effect**: one leaked kernel grant per thumbnailed document; after enough leaks, picked or bookmarked files stop
  opening until relaunch. Needs many files in one session.
- **Fix**: a `defer { url.stopAccessingSecurityScopedResource() }` scoped to each piece of work (thumbnail, coordinator
  accessor, each early return); keep the copy item's deinit.
- **Risk**: low.
- **How to verify**: send ~50 PDFs/images from Files in one session, then pick another file: it still opens. Temporary
  debug log of the start/stop balance.
- **Effort**: S. **Confidence**: high.

### I-36. Picking from Files/iCloud reads metadata synchronously on main, and iCloud-only files are fully decoded on main — `partial (f3325f34)`

- **Status**: descriptions built on a background queue; thumbnails via ImageIO (768 px max, oriented) and a private coordination queue. Not done: `asset.load(...)` async metadata and QLThumbnailGenerator (the sync AVAsset reads now run off main).

- **Severity**: medium. **Category**: perf.
- **Evidence**: `ChatControllerOpenAttachmentMenu.swift:1393` calls `iCloudFileDescription(url)` on main; for local
  files `descriptionWithUrl` runs synchronously (`ICloudResources.swift:208-210`), creating a bookmark and using the
  deprecated synchronous `asset.commonMetadata`, `asset.duration`, `asset.metadata(forFormat:)` (`:146-176`). For
  iCloud-only files the NSMetadataQuery observer (`:222`) and the thumbnail coordination (`:339`) use
  `OperationQueue.main`, and `complete()` runs `Data(contentsOf:)`, `UIImage(data:)`, a 256-px scale, JPEG and PDF
  rendering (`:313-319`) there. **Corrected**: for local files the thumbnail runs on the fetch queue; the main-thread
  full decode is only for files not yet downloaded.
- **Effect**: picking several audio files freezes the chat UI; a 48 MP photo or large PDF from iCloud Drive is decoded
  fully on main (hundreds of MB spike, jetsam risk).
- **Fix**: `|> runOn(Queue.concurrentDefaultQueue())` for `descriptionWithUrl` and `asset.load(.duration, .commonMetadata)`;
  thumbnails via `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize: 256`) and
  `QLThumbnailGenerator` for documents; coordinate on a private OperationQueue.
- **Risk**: low; keep the 256-px, 0.5-quality output.
- **How to verify**: Time Profiler while picking 10 FLACs and one 48 MP HEIC from iCloud Drive: no main-thread stalls,
  lower Allocations peak, identical thumbnails.
- **Effort**: M. **Confidence**: high.

### I-37. Pasting an MP4 loads the whole file into RAM on main; `pasteboard.items` loads every representation — `done (ff598dbc)`

- **Status**: MP4 copied to a temp file off main (`ChatTextInputPanelPasteData.video(URL)`); images read per item and type instead of `pasteboard.items`. The story composer's TextFieldComponent paste is unchanged. ChatTextInputPanelNodeTests pass; not yet verified in a built app.

- **Severity**: medium. **Category**: memory.
- **Evidence**: `submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift:5800`
  `pasteboard.data(forPasteboardType: "public.mpeg-4")`; `:5810` `for item in pasteboard.items { … }`, which pulls every
  type of every item across XPC synchronously. **Corrected**: a `.mov` copied from Photos
  (`com.apple.quicktime-movie`) does not match, so the spike applies to MP4 representations; the PNG histogram
  (`ImageTransparency.swift`) runs only for a single image with alpha (`:75-80`).
- **Effect**: pasting a large MP4 allocates its full size as one `Data` on main (freeze, jetsam risk).
- **Fix**: use `UIPasteboard.general.itemProviders` with `loadFileRepresentation(forTypeIdentifier:)` for movies,
  GIFs and HEICS and send from the temp file; load images with `loadObject(ofClass: UIImage.self)` off main; keep the
  memoji/sticker detection order and the fork's `pasteboardMayHoldMedia()` gate.
- **Risk**: medium. The send flow takes `.video(Data)` and needs a file-URL variant.
- **How to verify**: copy a large MP4 (e.g. from Files) and paste into a chat with the memory gauge open: today a spike
  of the file size, after flat. GIF, sticker and memoji paste still route correctly.
- **Effort**: M. **Confidence**: high.

### I-38. Drag and drop into a chat accepts only images — `done (ccb69afc)`

- **Status**: drops of videos and files accepted; videos/images to the paste screen, other files sent as documents; text and links left to the input. Not yet verified in a built app.

- **Severity**: low. **Category**: modernization.
- **Evidence**: `submodules/TelegramUI/Sources/ChatController.swift:10154`:
  `session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])`; `:10172-10194` loads `UIImage` objects.
  **Corrected**: the perf half is refuted (see below).
- **Effect**: on iPad and in multitasking, dragging a video, PDF or other file from Files or Safari onto a chat is
  refused.
- **Fix**: also accept `UTType.movie`, `UTType.item`, `UTType.fileURL`; load with `loadFileRepresentation` into a temp
  file and reuse the document-picker send path.
- **Risk**: low to medium (a new input path).
- **How to verify**: iPad simulator: drag a .mov and a .pdf from Files into a chat; both are accepted and sent.
- **Effort**: M. **Confidence**: high.

### I-39. The screen-sharing extension allocates a pixel buffer per frame, an AudioConverter per audio buffer, and waits on a semaphore nothing signals — `done (5c5e96a2)`

- **Status**: CVPixelBufferPool with IOSurface, per-plane copy, no semaphore, one AudioConverter per format with a reused buffer and a non-EOF exhaustion status. Needs the device check in the spec (chroma, audio clicks, memory).

- **Severity**: medium. **Category**: perf.
- **Evidence**: `Telegram/BroadcastUpload/BroadcastUploadExtension.swift:254` `CVPixelBufferCreate(…)` per frame with
  no pool and no IOSurface attributes; `:288-291` a `DispatchSemaphore(value: 0)` whose `signal()` is commented out, so
  each frame waits the full 1/30 s; `:462-505` `AudioConverterNew`/`Dispose` and `Data(count: 65536)` per audio buffer;
  `:264-269` copies with `CVPixelBufferGetBaseAddress`/`GetBytesPerRow` on a bi-planar buffer. This is
  `EmbeddedBroadcastUploadImpl`, selected when `ios_use_inprocess_screencast != 0` (`PresentationGroupCall:1229-1238`;
  the flag name reads inverted).
- **Effect**: ~4.5 MB allocated per frame at 30 fps, buffers held by the encoder push toward the extension's 50 MB
  limit; non-IOSurface buffers force a VideoToolbox copy; a fresh resampler every ~20 ms risks clicks and costs CPU.
- **Fix**: one `CVPixelBufferPool` with `kCVPixelBufferIOSurfacePropertiesKey` (recreated on size/format change); copy
  per plane; drop the semaphore (the 30 fps timestamp gate exists); one AudioConverter per input format with leftover
  state and a reused output buffer.
- **Risk**: medium. Quality and timing need a device test.
- **How to verify**: device, group call, screen share with app audio while the flag selects the embedded path:
  extension memory flat and well under 50 MB, correct chroma, no audio clicks, lower CPU.
- **Effort**: M. **Confidence**: medium (the plane-copy correctness needs a device check).

### I-40. Live location runs GPS and compass at full rate in the background, and any map asks for Always access — `partial (745f2990)`

- **Status**: Always requested only for live location; live location without a map open uses a 10 m filter and no heading (DeviceLocationManagerTests). Not done: `CLLocationUpdate.liveUpdates()` / `CLBackgroundActivitySession` on iOS 17+.

- **Severity**: medium. **Category**: perf.
- **Evidence**: `submodules/DeviceLocationManager/Sources/DeviceLocationManager.swift:56-59`
  (`kCLLocationAccuracyNearestTenMeters`, `kCLDistanceFilterNone`, `.other`, `pausesLocationUpdatesAutomatically = false`);
  `:115-121` the first subscriber in any mode, including `.preciseForeground`, calls `requestAlwaysAuthorization()` and
  `startUpdatingHeading()`. `LiveLocationManager.swift:116` pushes `.preciseAlways` and sends one update per 4 s
  (`:125-128`), discarding most fixes.
- **Effect**: hours of live location keep continuous GPS and magnetometer callbacks while stationary (battery). Users
  who granted When In Use get the "Change to Always Allow?" upgrade prompt from the location picker. **Corrected**: it
  is a one-time prompt per install, not on every map open.
- **Fix**: request Always only for `.preciseAlways`, When In Use otherwise; while live location runs in the background,
  `distanceFilter` 10-25 m, consider `.otherNavigation`, stop heading (resume in foreground). iOS 17+:
  `CLLocationUpdate.liveUpdates()` with `CLBackgroundActivitySession`; keep the current path for 15-16.
- **Risk**: medium. Viewers may see fewer heading and position updates.
- **How to verify**: one hour of stationary live location in the background; compare Energy Organizer / Settings ▸
  Battery. Open the location picker with When In Use: no Always prompt.
- **Effort**: M. **Confidence**: medium.

### I-41. On the first photo grant, Limited is treated as full access and the gallery does not update that session — `done (a42d0e19, d5e15bcc)`

- **Status**: `.readWrite` request and status everywhere; observer registered for authorized or limited, also from the request callback.

- **Severity**: low. **Category**: bug.
- **Evidence**: `submodules/TelegramUI/Components/MediaAssetsContext/Sources/MediaAssetsContext.swift:20-23` registers
  the change observer only in init and only if `PHPhotoLibrary.authorizationStatus() == .authorized`; `:98-104` the
  legacy `requestAuthorization` reports `.authorized` for a Limited grant, while `mediaAccess()` (`:88`) uses
  `authorizationStatus(for: .readWrite)`. `MediaPickerScreen.swift:1826` shows Manage only for `.limited`.
- **Effect**: in the session where access is first granted, choosing Limited hides the Manage banner, and new photos do
  not appear in the attachment grid until a later session.
- **Fix**: `requestAuthorization(for: .readWrite)` and `authorizationStatus(for: .readWrite)` everywhere; register the
  observer when the status becomes `.authorized` or `.limited`, including from the request callback.
- **Risk**: low.
- **How to verify**: `xcrun simctl privacy booted reset photos org.klaipher.Nanogram`, open the attachment menu, choose
  Limited: Manage banner shows; take a photo in Camera and return: the grid updates.
- **Effort**: S. **Confidence**: medium.

### I-42. Add Proxy reads the clipboard on open, triggering the paste prompt — `partial (c6023009)`

- **Status**: no clipboard read on open (`hasStrings`/`hasURLs` only); the text is read when Paste is tapped. Not done: `detectPatterns` / `UIPasteControl`, so the tap itself may still show the system prompt. SettingsUITests pass.

- **Severity**: low. **Category**: modernization.
- **Evidence**: `submodules/SettingsUI/Sources/Data and Storage/ProxyServerSettingsController.swift:344`
  `let pasteboardText = UIPasteboard.general.string ?? ""` while building the controller for every new proxy.
- **Effect**: with another app's content on the clipboard, iOS 16+ shows "Nanogram would like to paste from …" as the
  screen opens.
- **Fix**: `UIPasteboard.general.detectPatterns(for: [\.probableWebURL])` (no prompt), and only on a match offer a
  "Paste proxy link" button (`UIPasteControl` on iOS 16+) that reads after the tap.
- **Risk**: low.
- **How to verify**: copy text in Safari, open Add Proxy: no prompt; copy a tg://proxy link: the paste button appears
  and fills the fields.
- **Effort**: S. **Confidence**: high.

### I-43. Plist and AppDelegate cleanups: unused `fetch` mode and `.refresh` task id, dead activity type, `fatalError` on unknown authorization — `done (d5e15bcc)`

- **Status**: `fetch`, `.refresh` and `RemindAboutChatIntent` removed; `@unknown default` treated as denied.

- **Severity**: low. **Category**: modernization.
- **Evidence**: `Telegram/BUILD:1871` UIBackgroundModes `fetch` and `:1753` permitted `{bundle}.refresh`, with no
  handler anywhere (no performFetch, setMinimumBackgroundFetchInterval or BGAppRefreshTask; AppDelegate `:1661`
  registers only `.cleanup`). `NSUserActivityTypes` lists `RemindAboutChatIntent` (`BUILD:1849`) with no Swift
  reference. `DeviceAccess.swift:244`, `:269`, `:294`, `:447`, `:523`: `@unknown default: fatalError()`. (Badge API is
  in I-22.)
- **Effect**: declared capabilities that do nothing (App Review can question `fetch`); a future authorization status
  would crash instead of being treated as denied.
- **Fix**: remove `fetch`, `.refresh` and `RemindAboutChatIntent` (or implement a BGAppRefreshTask); replace
  `fatalError()` with a denied default.
- **Risk**: low.
- **How to verify**: build and diff the Info.plist: only these keys change.
- **Effort**: S. **Confidence**: high.

---

## Already good

- `ShareRootController`'s fork-added `ShareProcessActivity` follows Apple's 0xdead10cc guidance for extensions.
- The NotificationService message path has one connection deadline (`remainingBudget`, a 15 s poll cap) and an
  offset-aware `DataValue` buffer; the story path (I-14) should copy them.
- `WidgetDataContext` re-reads widget configurations every 60 s and on foreground instead of every 10 s (`9bc6231a`);
  only the background gating is missing (I-28).
- The app's own donations respect the passcode and IntentsSettings (`TelegramIntents.swift:58-75`), and donated and
  displayed notification intents are kept separate.
- `siriSendMessageTarget` already accepts a plain `<id>`; Siri checks every recipient with the same rules when
  resolving and sending (`siriRecipientDecision` / `siriRecipientAccepted`).
- `806ff160` gives NSE-donated call intents an account-qualified, packed identifier
  (`IncomingCallNotifications.callBackIdentifier`) with unit tests; the same pattern fits I-6, I-12 and I-25.
- `afac00d5` / `587800e6`: extensions open read-only with no accounts instead of trapping on a bad atomic state.
- Share to Story already uses `loadFileRepresentation`.
- `pasteboardMayHoldMedia()` checks pasteboard types without reading contents, so it raises no paste prompt.
- Spotlight indexing runs off the main thread and only when the Contacts suggestion setting is on.

## Refuted after checking

- Network loss after upload produces a false "sent" (I-1): MTProto keeps retrying, so it stalls; it is not an error.
- The notification extension files group conversations under the message author (I-12): it uses the chat id
  (`interactionAuthorId = peerId`).
- Dropping many photos decodes them on main (I-38): `loadObjects` UIImages decode lazily, and the transparency check
  runs only for a single image with alpha.
- Sharing a 1 GB file loads it into NSData (I-11): files are read with `NSDataReadingMappedIfSafe`, which is
  file-backed.
- The Siri Contacts gate breaks share-sheet suggestions (I-24): those go to the Share extension, not the Intents
  handler.
- Adding `.privacySensitive()` alone redacts the widget when locked (I-23): the views call `.unredacted()`.
- Pasting a `.mov` copied from Photos loads it into RAM (I-37): only `public.mpeg-4` is read that way.
- Local Files picks are fully decoded on main (I-36): only iCloud-only files are; local thumbnails use the fetch queue.
- A typical notification photo needs 4-12 serial round trips (I-15): the usual "y" size is 100-300 KB, 1-3 trips.
- Ordinary custom emoji crash the notification extension (I-16): Lottie renders 40×40 and static emoji are 100×100.
- Notification logging costs CPU with logging off (I-21): `Logger.log` takes an autoclosure and returns early.
- The Always-location prompt appears on every map open (I-40): it is a one-time upgrade prompt per install.
- Fixing `self.items` lets Spotlight pick up a late avatar (I-32): nothing re-emits until the contacts list changes.
- The cleanup task's double `setTaskCompleted` is harmful (I-43): harmless; dropped.
- Dead availability checks at `TelegramIntents.swift:236/242` (I-11): wrong lines; the real ones are `:58`, `:217`, `:223`.

## Not checked

- Nothing was built, run, profiled or tried on a device; every memory, time and battery figure is an estimate.
- Whether iOS surfaces incoming-only (NSE) donations in the share sheet, and whether `INInteraction.deleteAll()` from
  the app also removes the NSE's donations (I-12).
- Whether Spotlight can read an app-group `thumbnailURL` (I-32); Siri's mapping of `INStartAudioCallIntent` (I-30);
  the bi-planar copy in the broadcast extension (I-39); WidgetKit's actual reload frequency (I-27); how often the
  account-manager open fails on real devices (I-26); how often the story download triggers jetsam (I-14).
- Sharing out of Nanogram (UIActivityViewController, Transferable), universal links and associated domains, PushKit /
  CallKit incoming-call flow beyond the handle encoding, Apple Watch, CarPlay and Live Activities were outside this
  review.
- `NotificationService.swift` and `AppDelegate.swift` were read at HEAD `a1d25f70`; uncommitted edits by other
  workflows were not reviewed. Only `806ff160` (call back) landed in this area since.
