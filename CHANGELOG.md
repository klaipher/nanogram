# Nanogram iOS changelog (private)

Newest first. Internal notes for each TestFlight build; testers see the What to Test notes instead.

## 13.1.2 (202611041250) — 2026-11-04 — daac83e2

Uploaded to TestFlight; What to Test notes set by `tg testflight` after processing. dSYMs: ~/Library/Application Support/Nanogram/dsyms/202611041250.
Two earlier attempts the same day did not reach testers: 202611041214 was built but not uploaded (the export is named Nanogram.ipa since the branding change; the upload looked for Telegram.ipa, fixed in cc0f711f), and 202611041227 was uploaded and rejected by App Store Connect with ITMS-90626 (Siri vocabulary phrases still named INStartAudioCallIntent after the extension moved to INStartCallIntent; fixed in b923700d).

Changes since build 202611031553 (a449bd87): `git log a449bd87..daac83e2`. Private notes; not shown to testers.

### Shared core with the Mac (core merge)
- The Mac core (`mac/core`) is merged into `main`; Mac-only behaviour stays behind `#if os(macOS)` (48 kHz audio, AV1 decode threads, untagged frames, `nw_path_monitor`, ThreadPool QoS — the QoS mapping was briefly on iOS and is Mac-only again, 0e6cf57d). Ports that now run on iOS too: SQLite connections opened `NOMUTEX` (single-queue), share-extension 256-page cache, VACUUM never crashes and skips huge databases, FTS self-heal, cheap `exists()` (R2-38..43); 10-bit/HDR decode, passthrough colour from the stream's VUI (895eaaef), scrub and cached previews tagged sRGB instead of Display P3 (86064f5e via the merge); Ogg Opus resume continues the stream; local translation falls back to the server; history preload stops replaying once a chat has no hole.
- WebRTC: 12 tg_owt security and crash fixes on `third-party/webrtc` (`klaipher/webrtc` branch `nanogram-security-fixes`, 2c6b83a); allow-list of the 7 differing seam files.
- Parity gate (`tools/dev/parity`, `docs/mac-core-paths.txt`), shared native-library versions (`native-libs.json`), module settings table, shared cache cleanup (`tools/dev/cachegc`, Bazel disk cache cap 30 GB), pre-push hook; the hook now drops inherited `GIT_*` variables (3534f52c) after a push from a worktree turned the main checkout bare.
- `.gitmodules`: webrtc from `klaipher/webrtc`, tgcalls tracks `nanogram-shared` (afdc8092).

### Calls
- tgcalls pinned to the merged `nanogram-shared` branch (54220d6c): one switch class `CallsRuntimeSwitches`, one Streams & Calls Debug Settings section, low-risk fixes always on; batch C (call screen stops drawing at rest, livestream render loop follows what plays, thermal video ladder, background video), group video frames outlive their command buffer and only visible tiles are requested, screen-share frames copied per plane; H.265 start bitrate and decoder/pool reset caps; legacy H.264 check fixed; review fixes (still screen keeps reaching the encoder, ducking off by default, request hysteresis).
- Incoming call notifications: caller photo from `INStartCallIntent`, none while locked or with names hidden, call back from the right account and on the main queue; Phone Recents and Siri call back 64-bit ids as video when it was.

### Sending, media and storage
- Pending sends never wait forever on a missing thumbnail, transform or lost answer; failures go to the critical log.
- HLS video writes each byte once; MediaBox and SQLite count their writes (`DiskWriteAccounting`, hourly and background reports); database writes stop before a background task ends (0xdead10cc).
- GIFs: MPEG-4 Part 2 GIFs play instead of freezing; GIF tiles cover video stickers on the reused pixel-buffer path.
- MultipartUpload 128 KB parts for small files and six in flight; FetchV2 adaptive window; TCP keepalive 30 s idle.
- Wallet state requests back off and retry until the server answers.

### iPad
- Resizable chat-list column, window controls, minimum size, accent tint, text size, Live Text, translation and share anchors; in-app cameras keep running in Split View and Stage Manager; Power Saving follows the system (also on iPhone: heat, Low Power Mode, iOS 27 reduced resource usage); keyboard band and sticker panel fixes.

### Extensions, privacy, branding
- Share extension: attachments load as files, large videos no longer freeze share-to-story, failed sends reported, Send in HD.
- Widgets hide text and counts while passcode-locked; Spotlight indexes no contacts while a passcode is set; Proxy no longer reads the clipboard; Location asks for Always only for live location.
- Branding: Nanogram in Siri phrases, bundle names, language packs, QR login, welcome screen and calls; a lint keeps Telegram's name and logo out.
- Voice messages: correct progress on the first play.

### Siri
- Vocabulary phrases name INStartCallIntent in all 20 languages, matching the extension (b923700d); `test_siri_vocabulary.py` keeps every phrase within the extension's IntentsSupported.

### Tooling
- `tg testflight` uploads the exported `.ipa` whatever its name (cc0f711f); Postbox TimeBasedCleanupTests wait for the database to open (bca4f362); lint fixes for the merged Mac core code (57a3839a); TgVoipWebrtc host tests take NDEBUG from the library's flags (daac83e2).

## 13.1.2 (202611031553) — 2026-11-03 — a449bd87

Uploaded to TestFlight; App Store Connect processing: VALID; What to Test notes set. dSYMs: ~/Library/Application Support/Nanogram/dsyms/202611031553.

Changes since build 202611031231 (afac00d5). Private notes; not shown to testers.

### Calls
- **Incoming calls ring as a notification without the filtering entitlement** (33dc472b). The Notification Service extension gave every call push to CallKit with `reportNewIncomingVoIPPushPayload`, which iOS only allows with `com.apple.developer.usernotifications.filtering`. Nanogram doesn't have it, so iOS refused every call and the push was dropped. Without the entitlement, or when CallKit refuses, the call now shows as "<caller> is calling you" with the ringtone, and tapping it opens the caller's chat on the right account. Whether the extension has the entitlement is the Info.plist flag `NanogramNotificationFiltering`, which Telegram/BUILD writes from the same condition that grants the entitlement.
- **Call pushes are never quieted or removed** (a21301a7). If the extension leaves a call push empty, the server's alert and sound are passed through unchanged instead of becoming a silent placeholder that removes itself.
- **Every VoIP push reports a call to CallKit** (7736c798). Exits with no report (no payload, decode or decrypt failure, unknown key, no account state yet, bad JSON) now report a placeholder call and end it at once, so iOS keeps delivering VoIP pushes. The rule lives in `VoIPPushCallReport` (TelegramCallsUI).
- **The call notification stops ringing once the app rings** (0e50191c). The marker key moved to `IncomingCallNotifications`. The VoIP handler removes the caller's notifications when CallKit accepts the report. With CallKit off, SharedAccountContext removes them when the call stops ringing. The app's sweep drops any older than 90 s.
- **registerDevice failures are logged** (074bc0ff): the error, token type and sandbox flag (never the token). The behaviour is unchanged.
- Known risk, not covered by a test: if both a regular push and a VoIP push arrive for one call, the extension's notification may arrive after the app has already removed it, and ring over CallKit.

### App extensions (Siri, widgets, Share, notifications)
- **No crash when the account manager's state is missing** (87b20553). Extensions open with `removeDatabaseOnError: false`, which hit `preconditionFailure()` in AccountManagerImpl.init when `accounts-metadata/atomic-state` was missing or couldn't be decoded. They now open with the legacy tables' records, held in memory only.
- **An extension's in-memory state is never written** (583e7b97). `isStateInMemoryOnly`: no atomic-state sync, no legacy table writes, and the access challenge resolves without migration. Before this, the Share extension could write a keychain passcode, and the app's first launch then didn't count as a fresh install.
- **Only a missing file falls back to the legacy tables** (587800e6). A file that exists but can't be read or decoded opens with no accounts (keeping the legacy passcode so the extension still locks) and is never overwritten. The app keeps upstream's rebuild.

### Reactions and stickers
- **Reactions draw on the CPU renderer, as upstream does** (269bdd54). Under "GPU for large", reactions (240–320 px) used Metal and often set it up on the main thread when tapped, which left them empty for a few seconds.
- **Animation cache: converted items go into place on a dedicated store queue** (63a5b341), not behind every queued conversion on the fetch queue.
- **Sticker frames survive a view resize** (e821543a). A UIImageView subclass restores contents that were set directly.
- **Metal renderer setup moved to a utility queue after launch** (503e429a), via `AnimatedStickerMetalPrewarm`.
- **Reaction hand-off waits for the button's first frame** (1e7e0bc8, then f9b90fe3 with no timeout). `ReactionIconContentGate` runs the hand-off on `InlineStickerItemLayer`'s first real frame (the silhouette placeholder doesn't count; a449bd87 adds a test). It runs at once when the button switches to another reaction, and is dropped on reset.
- **Missing effect file: hand-off at once** (ac48011c). The log line is written only when the missing file changed the outcome (888f112b).
- **Double tap waits for the new button's first frame** (393ba10e), through `ReactionIconView.handOffAnimation(from:)`.
- **Long-press and stars reactions bridge a button with no frame yet** (1783031d). A snapshot of the reaction node, or the star itself, stays in the button until the first frame (`handOffAnimation(from:adoptingAt:)`, `ReactionContextNode.makeEmptyButtonBridge`).
- **A new animation layer starts hidden while a stand-in is in place** (e3a1503b).
- Known cosmetic issues on a cold cache:
  - A long-press built-in reaction may briefly show both the snapshot and the reaction node.
  - The bridge snapshot is about half the final size.
  - The stand-in star is a live SCNView until the first frame.
  - A double tap with a custom emoji, and `StandaloneReactionAnimation.cancel()`, can still show an empty button.
  - There is no timeout: if no frame ever arrives, the stand-in stays as long as the button exists.

### Tooling
- tg testflight: keeps dSYMs for every build (08de7474) and archives only this build's dSYMs, keeping the newest 20 builds (9cc7d387, 0241f014). Notes are required (7c546dfd). Exit 3 means uploaded but notes not set (747d6629); exit 4 means Apple rejected the build (0241f014). Fixed a SIGPIPE on large ipa listings (45fd0e07).
- tf_notes.py: retries rate limiting and timeouts (dca4c9bb).
- tg device: warns that a development-signed install gets no pushes or calls (58ef9dc6).
- Docs: d0fc02b9.
