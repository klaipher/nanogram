# Upgrading vendored libraries (FFmpeg, SQLCipher)

### Upgrading FFmpeg (a submodule since the shared-libraries plan W1.1)

`submodules/ffmpeg/Sources/FFMpeg/ffmpeg-9.0.2` is the `nanogram` branch of klaipher/FFmpeg (one branch, one pin, shared with Android); the Nanogram patches below are commits on that branch, not edits in this tree. To upgrade: rebase the fork branch onto the new release tag there, move all three pins the same day, then do the two edits below. The directory name stays `ffmpeg-<ver>` for the BUILD glob and the Mac `build.sh` autodetect.

FFmpeg is built from source by the `libffmpeg_build` genrule in `submodules/ffmpeg/BUILD`. Dropping in
a new `Sources/FFMpeg/ffmpeg-<ver>/` tree needs exactly two edits, both in that file (7.1.1 → 8.1.2,
done 2026-08-01, was a two-line change; 8.1.3 → 9.0.2, done 2026-10-31, needed only the version), plus re-applying the
local patches: `libavformat/mov.c` resets `sc->stsd_count` before allocating and after freeing the
stsd extradata arrays; `libavcodec/videotoolbox.c` (marked "Local patch (Nanogram)") writes only the
chroma location when VideoToolbox already tagged the frame with the colours FFmpeg would set (the full
rewrite plus read-back was 0.74 s of IOSurface IPC per device session), and skips
`VTDecompressionSessionWaitForAsynchronousFrames` once the synchronous decode has delivered its frame.
`UniversalMediaPlayerTests` (`FFMpegVideoToolboxAttachmentTests`) pins the resulting attachments.
Find them by diffing the outgoing tree against its pristine release tarball:

1. **`FFMPEG_VERSION`** — the only place the version is pinned. `build-ffmpeg-bazel.sh` takes it as
   `$5` and derives `$SOURCE_DIR/ffmpeg-$FF_VERSION`.
2. **Prune `ffmpeg_header_paths`** of headers the new release removed. That list doubles as the
   genrule's declared `outs`, each `cp`'d twice (to `Public/` and `Public/third_party/ffmpeg/`), so a
   header that no longer exists **hard-fails the build**. 8.x dropped `libavcodec/avfft.h`
   (deprecated lavc 60.25.100, removed in FFmpeg 8); nothing here uses the avfft API. 9.0 removed
   none of the listed headers.

The simulator (`ios_sim_arm64`) builds the `release` variant like device, so simulator profiles are
representative; only `darwin_arm64` still uses `debug` (`--disable-optimizations`).

Two non-obvious things when surveying for breakage:

- **App consumers are guarded lower-bound only** (`#if LIBAVFORMAT_VERSION_MAJOR >= 59`, and its
  `< 59` complement), so removed APIs sit in dead branches and majors can climb freely — 9.0.2 is
  lavc/lavf 63, lavu 61, swr 7. That is why `avcodec_close`, `swr_alloc_set_opts` and
  `av_get_default_channel_layout` still appear in `FFMpegBinding/Sources/*.m` and
  `tgcalls/group/{AudioStreamingPart*,VideoStreamingPart}.*` despite being gone from FFmpeg 8.
- **Don't validate configure component names by grepping `configure`** — it derives them at runtime
  from `libavformat/allformats.c` and `libavcodec/{allcodecs,parsers,bitstream_filters}.c` /
  `hwaccels.h` (`extern const FFOutputFormat ff_<name>_muxer;`). Always control-diff the result
  against the outgoing version, because several names in the flags (`libopus` demuxer/parser, `mp3`
  parser, `libvpx_vp9` encoder) have always been inert and otherwise read as a fresh regression.

The `pkg-config` shim in `Sources/FFMpeg/` strips version qualifiers and always answers `--exists`,
so `require_pkg_config "dav1d >= 1.0.0"` cannot fail on version — only the wrapper's compile against
the vendored headers can. Verification is the full `Make.py build` (there is no isolated smoke
build); afterwards confirm `bazel-bin/submodules/ffmpeg/Public/libavutil/ffversion.h` actually reports
the new version rather than trusting a cache hit. Note that a header dropped from the list lingers
under `bazel-bin/.../Public/` — bazel does not delete undeclared outputs, so check its mtime before
believing it is live.

### Upgrading the vendored SQLCipher

`submodules/sqlcipher` is the SQLCipher **amalgamation** (one `Sources/sqlite3.c` plus the three
public headers), not the source tree. Now SQLCipher 4.20.0/SQLite 3.54.1 (from 4.4.2/SQLite
3.33.0, first upgraded on 2026-09-22), which picked up the upstream WAL-reset corruption fix (SQLite 3.51.3) that matters
because the app and the notification extension write and checkpoint the same WAL database.

A SQLCipher release archive does not ship the amalgamation; generate it from the tree:

```sh
./configure --with-tempstore=yes --enable-fts5 \
  CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown -DSQLCIPHER_CRYPTO_CC" \
  LDFLAGS="-framework Security -framework Foundation"
make sqlite3.c sqlite3.h     # also copies sqlite3ext.h and ext/session/sqlite3session.h to the root
```

(needs `/usr/bin/tclsh`; the configure flags do not bake into the amalgamation, every feature is
still selected by the `-D`s in `BUILD`). Copy `sqlite3.c` to `Sources/` and the three headers to
`PublicHeaders/sqlcipher/`. Then check `sqlite3.c` for `#define SQLITE_VERSION` and
`CIPHER_VERSION_NUMBER` rather than trusting the archive name.

Non-obvious points:

- **Since SQLCipher 4.6 `sqlcipher.c` `#error`s** unless `SQLITE_EXTRA_INIT=sqlcipher_extra_init`,
  `SQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown`, `SQLITE_THREADSAFE` in {1,2} and
  `SQLITE_TEMP_STORE` in {2,3} are all defined. `BUILD` and `Package.swift` carry them; keep the two
  in sync.
- **Keep the amalgamation pristine.** The 2021 copy carried a hand edit that normalised SQLite's
  `MIN`/`MAX` macros to the `<sys/param.h>` spelling so clang's `-Wambiguous-macro` stayed quiet
  under `enable_modules`. That is now `-Wno-ambiguous-macro` in `BUILD` instead; do not re-patch.
- **Behaviour changes that touch `SqliteValueBox`:** `PRAGMA cipher_memory_security = OFF` is a
  no-op (memory security can only be turned on); `PRAGMA key` on a connection that has already
  decrypted a page is ignored with a log line, so re-keying means opening a new connection (which
  the value box already does); a keyless `PRAGMA cipher_plaintext_header_size` is still a silent
  no-op and only `cipher_default_plaintext_header_size` applies before `PRAGMA key`.
- The `-W#warnings` suppression is for `"gethostuuid() is disabled."`, which the amalgamation
  emits on iOS. A `clang -fsyntax-only` pass with the `BUILD` defines is a 1-second smoke check.

**Self-heal policy in `SqliteValueBox`** (2026-09-22, tested in
`Postbox/Tests/SqliteValueBoxRecoveryPolicyTests.swift`): the app and its extensions share one
WAL database, so deleting it to recover is only ever done by the owning read-write connection
(`removeDatabaseOnError` is folded with `!isReadOnly && !isTemporary` in `init`), always as the
whole `db_sqlite` + `-wal` + `-shm` set (`removeDatabaseFiles`), and never on a transient result.
`SQLITE_BUSY`/`LOCKED`/`IOERR`/`CANTOPEN`/… from the schema probe are not a verdict about the
file: the probe returns `.unavailable`, lock contention (`BUSY`/`LOCKED`/`PROTOCOL`) is retried
exactly once (each attempt already waits the 5 s busy timeout), and then the owner crashes
without touching files while a non-owner reports no database. The crash is deliberate: the owner's
`.error` result is mapped to a permanent `.upgrading(0.0)` by `accountWithId`, so returning nil
would hang the launch screen. Probe results (busy, disk full, I/O) never
feed a deletion fallback: those clear on relaunch or when space is freed, and deleting the account
database is not a recovery. The one valve is on a failed `sqlite3_open_v2` (`Database.open`): the
owner records the failure in `db_sqlite-open-failures` and wipes on the third consecutive one, but
only for errnos deleting could fix (EISDIR, EIO, unknown); EPERM and EACCES (data protection
before first unlock), descriptor exhaustion, out of memory and disk full never advance it, and a
successful open resets it. The same fold gates in-place reencryption
(`forceEncryptionIfNoSet`): a non-owner never rewrites the live file. Deleting `db_sqlite` alone
was the mechanism behind repeated "Corrupted DB at step, dropping": the relaunched app shared the
extension's still-mapped `-shm` with a different WAL file. `.tempkey` creation in `BuildConfig.m`
is serialized across processes with `flock` on `.tempkey.lock` for the same reason (two generators
would each key a database with material only one of them persisted).
One exception to delete-and-crash: `SQLITE_CORRUPT_VTAB` (extended code only) from an FTS5 statement makes
the owner rebuild that full-text index once per connection instead of deleting the database; plain
`SQLITE_CORRUPT` keeps the old policy (`SqliteValueBoxConnectionTests`). `releaseMemory()` never
checkpoints: it runs on entering the background, where a checkpoint's locks and syncs risk 0xdead10cc.
