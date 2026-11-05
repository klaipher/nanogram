# Media I/O invariants

## Media I/O invariants (MediaBox maps, lookahead reader, RangeSet, VACUUM)

- **`<id>_partial.meta` lags the partial file.** `MediaBoxFileContextV2Impl` writes the map every
  `defaultWritesPerMapSerialization` (16) writes and on completion, reset, truncation and close; the
  live map is in `MediaBox.liveFileMaps`. Any in-process reader that reads a partial file without
  the file context must consult `liveFileMaps` first (as `internal_resourceData` and
  `internal_resourceDataIsCached` do); reading the `.meta` from disk alone can miss up to 15 chunks
  and stall a streaming reader. The on-disk map only ever claims less than was written, so a crash
  costs a re-download; a torn map still fails its CRC/length check and is discarded
  (`MediaBoxMapSerializationBatchingTests`). Before `link()` publishes a completed file the data is
  ordered with `F_BARRIERFSYNC` (`ManagedFile.barrierSync`), not `fsync`. A context writes **no** map
  when it opens: a resource whose status is only looked at creates no file, and a missing map reads as
  empty (it used to write an empty `.meta` for every resource it opened; `MediaBoxWriteAccountingTests`).
- **The HLS player writes each streamed byte once** (`HLSStreamingStorage`, MediaPlayer). A segment is
  fetched into its MediaBox resource and served to hls.js from there (a cached one with no write and no
  fetch); the server source records what it served (`HLSServedSegments`), and an appended segment whose
  bytes are exactly a served range (confirmed byte for byte against the cache) becomes a
  `ChunkMediaPlayerPart.MediaBoxRanges` part (initialization range + segment range) that FFmpeg reads in
  place, holding the resource with `keepResource`. Only bytes hls.js changed, and hardware AV1 (played
  by AVFoundation from a path), still go through a TempBox `.mp4`. It used to be three writes per byte
  (a TempBox partial file, a copy into MediaBox, the `.mp4`) and two per cached replay (MetricKit
  2026-11-02: 35 of 101 disk-write samples). Probing is in memory (`extractFFMpegMediaInfo(data:)`).
  `HLSStreamingStorageTests` count the writes.
- **Disk writes are counted by writer** (`DiskWriteAccounting`, always on): MediaBox data per media
  type (`mediaBox.video`, `mediaBox.sticker`, … from the fetch's `contentType`), file maps, cached
  representations, SQLite WAL frames and checkpoints per database (from the WAL hook and the idle
  checkpoint), animation-cache items, the direct image cache, Spotlight, logs and the HLS temp files.
  AppDelegate logs one `Disk writes (hourly|background|foreground): …` line per hour and on each
  transition, and `SharedWakeupManager.releaseBackgroundTime` reports (`suspend`, from 1 MB) right
  before iOS may suspend the app: a process launched in the background for a push, then killed while
  suspended, gets no other report. Per-day totals are in `<root>/logs/disk-writes.json`, which Send
  MetricKit Reports includes, so a day's `logicalDiskWrites` can be split by writer. A new large writer
  should report to it. `sqlite3_wal_checkpoint_v2`'s `pnCkpt` is the WAL's *total* backfilled frames,
  so only its growth counts (`SqliteWalWriteAccounting`): summed per checkpoint, a WAL pinned by an
  extension's reader read 1.2 GB of checkpoints for 16 MB written.
- **The direct-fetch lookahead (`FFMpegLookahead`) reads from memory, not MediaBox, per read.** It
  answers "is it cached" from MediaBox's live range status and, once that covers the whole file,
  reads the complete file through one `pread` handle. Do not route its per-read path back through
  `MediaBox.resourceData`/`internal_*` calls (each one stat'ed and opened files: 38% of the thread).
- **RangeSet is `@inlinable`** (clients specialize it; 57-100x faster than the unspecialized calls,
  benchmark under the deep-audit fix-bench). Its invariant check runs only with `DEBUG`. Its
  `intersects` also returns true for a range that only touches the set (pinned by
  `//submodules/Utils/RangeSet:RangeSetTests`); keep that unless every caller is checked.
- **MediaBox's file indexes never crash the app** (`StorageBox`: `storage`, `cache-storage`; and
  `TimeBasedCleanup`'s scratch table). They open `SqliteValueBox(…, isDisposable: true)`: an open
  that fails or whose setup cannot be written returns nil, an unpreparable statement is skipped
  (reads find nothing, writes are dropped), a table whose creation failed is not recorded (the next
  write creates it), and transaction/step failures only log, even under strict error handling. A
  StorageBox whose file cannot be opened keeps its index in memory for that launch; it never
  deletes the file itself (the valve and corruption handling in `SqliteValueBox` do). The account
  database and the account manager keep the crash-and-relaunch policy (the default
  `isDisposable: false`). Device crash this fixed: 202611020509, StorageBox's reindex reaching
  `insertOrReplaceStatement`'s trap after `BEGIN`/`CREATE TABLE` failed silently
  (`StorageBoxUnavailableDatabaseTests`; `SqliteValueBox.busyTimeoutMilliseconds` lets a test hold
  a lock briefly).
- **`SqliteValueBox.vacuum()` never crashes** (busy, disk full, I/O errors are logged and return
  false). Background maintenance (the `BGProcessingTask` cleanup, external power) calls
  `Postbox.optimizeStorageIfNeeded()`: VACUUM only when free pages are >= 25% of the file, at most
  once per 7 days (marker file `storage-optimization-timestamp` in the Postbox directory), only with
  room for the copy, and never while the app is active. VACUUM blocks the Postbox queue: never call
  it from UI paths.
- **Edited video exports carry BT.709 colour tags** (`mediaEditorExportColorProperties`): the encoder
  already converts the composer's BGRA with BT.709, and untagged video up to 720x576 is decoded as
  BT.601. `MediaEditorTests` decodes an exported pure red back to (255, 0, 0).
- **CameraNeo circles are tagged BT.709 too** (`RoundVideoFrameProcessor.videoColorProperties`), and
  the BGRA output pool carries the 709 matrix (the matrix only, so the thumbnail made from the same
  buffer stays sRGB) as a propagated attachment, so the encoder's conversion and the tag agree. Until 2026-11 (and in upstream Neo) they copied the camera's BT.601 matrix into
  the tag while the encoder converted with 709, so skin decoded pinker (7d600b48's message wrongly
  says circles already tagged 709). Never tag with the camera's matrix: the shader has already
  decoded it. `//submodules/Camera/CameraNeo:CameraNeoTests` decodes red and a skin tone back.
- **CameraNeo decodes the camera's 601-tagged buffers as BT.709** (`RoundVideoFrameProcessor.decodeMatrix`,
  Debug Settings ▸ "Circle Colour Decode", `ExperimentalUISettings.videoMessageCameraMatrix`, default
  `.bt709`). The front camera's 420f buffers are tagged BT.601, but decoding them by that tag turned skin
  and lips ~7-9° towards magenta (neutrals unchanged) against Legacy, which asks the camera for BGRA, and
  the official app; re-decoding the same frames as 709 matched them to ~1 ΔE a*b*. That was measured on
  recordings, not yet A/B'd on the device: "Camera tag (old)" restores the tag-following decode and
  "BT.601" forces 601. A BT.2020 tag is followed under every option, and the range comes from the pixel
  format. Each recording logs one `colour:` line per camera (buffer matrix/primaries/transfer tags, 420f
  or 420v, size, active format, the decode used) to the CameraNeo log. `RoundVideoDecodeMatrixTests`.
- **Circle pause/resume** (`VideoMessageCameraScreen.resumeCameraCapture`): the paused frame stays sharp until
  the preview runs again, then cross-fades out on main (`isPreviewing` is KVO and may arrive off main). No blur,
  no loading shimmer on resume: the shimmer used to be faded in there and never out, and `LoadingEffectView`
  restarted its sweep on every layout (0.09 s while recording), a glow blinking at the circle's left edge
  (`VideoMessageCameraScreenTests`). CameraNeo's preview views switch their connection on the session queue
  (`CameraPreviewView.connectionQueue`), never on main, where it could wait for a `startRunning`/`stopRunning` in progress.
- **Gallery photo upload decodes at the upload size** (`downsampledPhotoLibraryImage`: PhotoKit
  image data, ImageIO thumbnail with the EXIF transform, then the same `resizedImage` step for the
  exact size and sRGB). Photos deeper than 8 bits, camera RAW and unreadable data fall back to the
  full-size PhotoKit path. The decode runs off `fetchPhotoWorkers`: its threads block until their
  photo is done, so work queued back onto them deadlocks an album send.
- **Legacy camera shutter:** `TGCameraCapturedPhoto` is built off the main thread; the first screen
  image of the most recent capture is decoded from its JPEG bytes kept in a single static slot.
