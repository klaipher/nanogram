# Local development

This fork tracks the official Telegram-iOS releases (currently **release-13.1.1**) with changes that make local
builds faster, keep disk usage bounded, and bring the build dependencies up to date. This page explains what was
changed and why, and how to work with the fork day to day.

## Quick start

```sh
git clone https://github.com/klaipher/telegram-ios-dev.git && cd telegram-ios-dev
tools/dev/tg setup        # git tuning, shallow submodules, local config files
# put your own api_id / api_hash in build-system/dev-configuration.json
tools/dev/tg doctor       # checks Xcode, the Metal Toolchain, config, submodules, free disk
tools/dev/tg project      # generate + open the Xcode project (simulator, no extensions)
tools/dev/tg build        # or build from the command line (debug simulator, no extensions)
```

Requirements: macOS 27, Xcode **27.1** (27.2 is verified to work; `tg` passes `--overrideXcodeVersion` like
upstream's own dev command), and ~25 GB free for the first debug simulator build (see the measurements below).
Two one-time Xcode steps, both checked by `tg doctor`:

```sh
sudo xcode-select -s /Applications/Xcode.app   # DEVELOPER_DIR is not enough: Bazel runs the
                                               # third-party build scripts without it
xcodebuild -downloadComponent MetalToolchain   # Xcode 26+ no longer bundles the Metal compiler
```

Simulator builds need no Apple developer account: they use `build-system/fake-codesigning` with provisioning
profiles disabled, the same setup upstream's own CI uses.

`tools/dev/tg help` lists everything. Common variants:

| Command | What it builds |
| --- | --- |
| `tg build` | debug, simulator, app only (fastest) |
| `tg run` | `tg build`, then install and launch on the test simulator (iPhone 17, iOS 27.2) |
| `tg build --full` | debug, simulator, with the Share/Notification/Intents/Widget extensions |
| `tg build --release` | optimized simulator build (for profiling) |
| `tg build --device` | debug device build. With the default fake codesigning it compiles, links and signs (run `tg fake-signing` once to install the public fake identity into its own keychain) but cannot be installed; for a real device set `TG_CODESIGNING` to your own profiles and certificates |
| `tg test //submodules/TextFormat:TextFormatTests` | one test target |
| `tg disk` / `tg clean` / `tg prune --yes` | inspect / trim / wipe build state |
| `tg new-module submodules/MyFeature` | a new Swift module with the strict Swift 6 preset and a host test |
| `tg strict-report` | Swift 6 concurrency problems per module (~15 min, see below) |
| `tg watch test` / `tg watch build` | the Apple Watch app (`Telegram/WatchApp`) and its unit tests in the watchOS simulator (xcodebuild, not Bazel; see `CLAUDE.md`, "Embedded watch app") |

Simulator builds produce `bazel-bin/Telegram/Telegram.app` (a directory, not a zipped `.ipa`); `tg run` installs and
launches it. Device builds still produce `bazel-bin/Telegram/Telegram.ipa`.

Logging in on the simulator: debug builds show a QR code on the "Your Phone" screen. Scan it in Telegram on your
phone (Settings → Devices → Link Desktop Device). Logging in by phone number can end on an "SMS Fee" screen (Telegram
charges for SMS codes in some countries), and the simulator cannot pay it. If the app is stuck on that screen, run
`xcrun simctl uninstall booted ph.telegra.Telegraph` and `tg run` again.

## Measured results

Debug simulator build without extensions (`tg build`) on a 10-core Apple silicon Mac with 32 GB RAM, Xcode 27.2.

| | Upstream setup (Bazel 9.2) | This fork |
| --- | --- | --- |
| Cold build | 17 min 51 s | **12 min 36 s** (critical path 475 s, from 715 s), with every library update below |
| No-op rebuild (`tg build` again) | 4.5 s (Bazel 2.4 s, re-analyzes 8,125 targets) | **1.8 s** (Bazel 0.3 s, nothing re-analyzed) |
| One Swift file changed (comment) | | 8.7 s |
| Bazel outputs + disk cache, actual disk used | ~22.5 GB | **~14.2 GB** (the 7.4 GB disk cache shares blocks with the outputs) |

`du` reports the disk cache at full size either way, because it counts copy-on-write clones twice; the numbers above
come from the change in free space. Downloaded dependencies (the repository cache) add about 4 GB, shared with
other Bazel projects on the machine.

## How the build system works (upstream)

- **Bazel with Bzlmod** (`MODULE.bazel`, lockfile checked in). The pinned binary is downloaded by
  `build-system/Make/Make.py` into `build-input/` and verified against the sha256 in `versions.json`.
- `Make.py` is the entry point. It reads a JSON configuration (bundle id, api id, team id), resolves
  codesigning, and calls Bazel with the right flags for one of four configurations: `debug_sim_arm64`,
  `debug_arm64`, `release_sim_arm64`, `release_arm64`.
- Xcode integration is `rules_xcodeproj` (BwB mode): Xcode drives Bazel, so the Xcode project and the CLI share
  the same build graph.
- Rust (MTProto engine, wallet engine) builds through `rules_rust` with every crate and toolchain archive pinned
  by checksum; Go is used only for a test tool (`go_sfu`).

The upstream setup is already in good shape: single-architecture builds, a Swift persistent worker,
`swift.cacheable_swiftmodules`, the global module cache, path remapping so outputs are cacheable, deterministic
archives (`ZERO_AR_DATE`), and `-Osize` + WMO + dead stripping only in release. The changes below target what is
left: unbounded disk growth, slow no-op builds, work that most local changes don't need, outdated dependencies, and
a few rough edges for a fork.

## What this fork changes

### Faster builds

| Change | Where | Effect |
| --- | --- | --- |
| Skip the 5 app extensions by default (`--//Telegram:disableExtensions`) | `tools/dev/tg build` / `project` | Share, Notification Service/Content, Intents and Widget are separate binaries that most UI work never touches. `--full` brings them back. |
| Generated build inputs are only rewritten when they change | `build-system/Make/FileSync.py`, `Make.py` | `Make.py` recreated `build-input/configuration-repository` (provisioning profiles, `variables.bzl`) on every run, so Bazel re-analyzed ~8,000 targets on every no-op build. No-op: 2.4 s → 0.3 s in Bazel. |
| `--watchfs` | `.bazelrc` | Bazel uses FSEvents instead of re-checking ~49k source files at the start of each build. |
| `core.fsmonitor`, `core.untrackedCache`, `feature.manyFiles` | `tg setup` (local git config) | `git status` in ~0.3 s on a ~49k-file checkout. |
| Shared, persistent disk cache by default (`~/.cache/telegram-ios/bazel-disk-cache`) | `tools/dev/tg` | Switching branches or running `bazel clean` reuses earlier outputs instead of rebuilding them. Shared between the CLI and the generated Xcode project. |
| Build-time tools unoptimized (`--host_compilation_mode=fastbuild`) | `.bazelrc` | ~860 tool actions (Rust proc-macros and build scripts, uniffi-bindgen, the SwiftTL generator) built at `-O0`, as Cargo does for build dependencies. The wallet-bindings tool chain was at the start of the critical path. Their output is unchanged. |
| apple_support layering check off (`APPLE_SUPPORT_LAYERING_CHECK_BETA=0`) | `.bazelrc` | A beta lint that changes no output; its module map generation took ~30 s at the start of every cold build. |
| Parallel `make` in the libvpx, libwebp, mozjpeg (now libjpeg-turbo) and libjxl build scripts | `third-party/*/build-*-bazel.sh` | They compiled on one core (libvpx alone took 104 s). |
| No `.ipa` for simulator builds (`apple.experimental.tree_artifact_outputs`) | `tools/dev/tg build` | Skips zipping the whole bundle on every build (~12 s of packaging, even for a one-line change). |
| Line tables only for third-party C/C++ in debug builds (`--per_file_copt=^third-party/.*@-gline-tables-only`) | `tools/dev/tg build` | WebRTC and the other libraries keep file:line backtraces but no variable info: smaller objects and faster compiles. Telegram's own code keeps full debug info. |
| Fixed `Make.py --bazelArguments` | `build-system/Make/Make.py` | The flag was parsed but silently dropped. It now reaches `build`, `test`, `query` and `generateProject` (last, so it can override defaults). |

### Less disk space

| Change | Where | Effect |
| --- | --- | --- |
| Bazel 9.3: copy-on-write disk cache | `versions.json` | Disk cache entries are APFS clones of the build outputs instead of second copies: ~8 GB saved on a debug build. |
| Disk cache garbage collection: 20 GB cap, 14-day max age | `.bazelrc` | Upstream passes `--disk_cache` with no limit, so it grows forever. Bazel now trims it in the background when idle. Change the limits in `user.bazelrc`. |
| `--experimental_repository_cache_hardlinks` | `.bazelrc` | Downloaded archives are hardlinked into `external/` instead of copied. |
| rules_xcodeproj with the clonetool-based copy tool | `MODULE.bazel` | Xcode builds copy outputs into DerivedData as APFS clones instead of with rsync. |
| Shallow submodules (`shallow = true`) | `.gitmodules` | `git submodule update` fetches one commit per submodule instead of its whole history (~400 MB more for webrtc, libvpx and td alone). |
| Apple rules no longer vendored as submodules | `MODULE.bazel` | Four fewer git checkouts; Bazel downloads the rules once into its repository cache. |
| History-free repository | git layout (below) | One snapshot commit per upstream release instead of upstream's full history: ~130 MB of git objects instead of ~890 MB. The whole checkout with submodules is ~1 GB. |
| `tg disk`, `tg clean`, `tg prune` | `tools/dev/tg` | See where space goes and reclaim it. |

### Updated dependencies

| Dependency | Upstream 13.1.1 | This fork |
| --- | --- | --- |
| Bazel | 9.2.0 | 9.3.1 (LTS patch release) |
| rules_apple | `ali-fareed/rules_apple` fork (submodule) | 5.4.0 + `build-system/patches/rules_apple-accept-any-certificate.patch`, the fork's only change |
| rules_swift | Sep 2026 commit (submodule) | 4.2.2 |
| apple_support | Aug 2026 commit (submodule) | 2.11.0 |
| rules_xcodeproj | Aug 2026 commit (submodule) | `main` @ b493ced (newer than the 4.1.0 release) |
| rules_rust / Rust | 0.74.0 / 1.98.1 + 19 hand-kept checksums | 0.75.0 / 1.99.1 (checksums known to rules_rust) |
| rules_cc, rules_shell, bazel_features, bazel_skylib | 0.2.20, 0.6.1, 1.51.0, 1.9.0 | 0.2.27, 0.8.0, 1.54.1, 1.9.2 |
| rules_go / gazelle / Go | 0.60.0 / 0.43.0 / 1.24.2 | 0.65.0 / 0.54.0 / 1.27.3 (gazelle 0.54 needs Go ≥ 1.24.12) |

Verified with the full app build (installed and launched in an iOS 27 simulator), the host tests
`//submodules/UrlWhitelist:UrlWhitelistTests`, `//submodules/MetalEngine:MetalPipelineCacheTests`,
`//third-party/libprisma:SyntaxHighlighterTests`, and the Go tool `//submodules/TgVoipWebrtc/tgcalls/tools/go_sfu`.

Bundled libraries (`third-party/`, `submodules/ffmpeg`, `submodules/sqlcipher`), each verified with simulator and
device builds plus the library's own checks:

| Library | Upstream 13.1.1 | This fork | Notes |
| --- | --- | --- | --- |
| BoringSSL | Mar 2024 snapshot (API 30) | 2ea3200c (API 43, Chromium 156 stable) | File lists generated by upstream (`src/gen/sources.bzl`); AES-IGE checked against CommonCrypto |
| FFmpeg | 8.1.2 | 9.0.2 | Telegram's `mov.c` patch kept; simulator now built optimized (release), like device |
| SQLCipher / SQLite | 4.19.0 / 3.53.4 | 4.20.0 / 3.54.1 | Postbox tests: 201 passed |
| libwebp | 1.3.2+ | 1.6.0 | |
| libvpx | 1.13.0 | 1.17.0 | arm64-simulator patch rebased |
| dav1d | 1.5.0+ (fork, no patches) | 1.5.4 | Submodule now points at code.videolan.org |
| openh264 | 2.4.1 | 2.7.0 | Telegram's patches kept; subcodec keeps POC type 0 (its 11 tests pass) |
| libjxl | 0.9.0 | 0.12.0 | Its upstream Bazel files removed: they made the package fail to load under Bazel 9 |
| mozjpeg → libjpeg-turbo | mozjpeg 4.1.5 | libjpeg-turbo 3.2.1 | Release archive pinned by checksum; decode pixel-identical, encode byte-identical (`MozjpegBindingTests`) |
| libyuv | 1887 | 1977 | Neon kernels built with `+dotprod+i8mm`, used only after a runtime CPU check |
| opus | 1.5.1 | 1.6.1 | |
| ogg | 1.3.4 | 1.3.6 | |
| rnnoise | 2021 | 0.2 | New model: much stronger noise suppression in group calls, +1.3 MB |
| Boost.Regex | 1.8x | 1.92.0 | |
| TDLib (`tde2e` only) | 1.8.49 | 1.8.69 | Group-call E2E: schema and API unchanged, upstream tests pass |

FlatBuffers is at 25.12.19 (2026-10-31): the generated Swift API now returns `FlatbufferVector<T>` for vector fields
instead of `xCount`/`x(at:)`, so about 55 read sites were migrated; the wire format is unchanged (buffers written by
24.12.23 decode byte-for-byte). Worth a manual check on a device: video calls (libvpx,
openh264, libyuv, BoringSSL in WebRTC) and group-call noise suppression (rnnoise).

Not updated: the gazelle 2.0 line (betas only). `rules_apple` and `rules_xcodeproj` use `archive_override` because
the versions needed are not in the Bazel Central Registry yet; switch them to plain `bazel_dep` versions once they are.

### Fork hygiene

- **One simulator pin for tests.** Upstream pins each of its 48 `ios_test_runner`s to its own CI's device/OS
  (mostly iOS 26.5), which is not installed with Xcode 27.2, so every app-side test failed before running. They
  all read `TEST_SIMULATOR_DEVICE` / `TEST_SIMULATOR_OS` from `build-system/bazel-utils/test_simulator.bzl`
  (iPhone 17 / iOS 27.2, the runtime matching Xcode 27.2) now; after an Xcode update, install its simulator (`xcodebuild -downloadPlatform iOS`) and change the pair there.

- **Absolute submodule URLs.** Upstream uses `../rlottie.git` and `../tgcalls.git`, which resolve relative to the
  remote. From this fork they would point at `github.com/klaipher/rlottie.git`, which doesn't exist; they now point
  at `TelegramMessenger/…` directly.
- **`.bazelversion`** matches `versions.json`, so plain `bazel` (via Bazelisk) works for the host-only test targets
  described in `CLAUDE.md`. The `Sanity` workflow checks that the two stay in sync.
- **`user.bazelrc`** (gitignored, loaded with `try-import`) for personal settings such as `--jobs` or a different
  cache limit, instead of editing the shared `.bazelrc`.
- **CI.** Upstream's `build.yml` ran a release build on every push to `master` on a `macos-13` runner, which can't
  have Xcode 27.1 and would fail while burning macOS minutes (billed at 10x in private repos). It is now manual
  only. `sanity.yml` runs on Linux in seconds: the `Make.py` unit tests, shellcheck, and the version-pin check.

## Swift strictness

Telegram's modules compile in the Swift 5 language mode, and 723 of 732 of them treat warnings as errors. A
build with Swift 6's complete concurrency checking (2026-10-30, Swift 6.4) reports **at least 24,480 problems in
563 modules**; the real number is higher, because the five largest modules' output was cut off and three modules
fail outright, which left their dependents (including the app's main `TelegramUI` module) unchecked. Fixing that
means rewriting much of Telegram's threading code and conflicting with every upstream release, so the existing
code stays in the Swift 5 mode. Strictness is applied where it is cheap instead
(`build-system/bazel-utils/swift_strict.bzl`):

| Macro | Settings | Used for |
| --- | --- | --- |
| `strict_swift_library`, `strict_swift_test` | Swift 6 mode, `-warnings-as-errors`, `-strict-memory-safety`, and every Swift 7 upcoming feature (`ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`, `ImmutableWeakCaptures`) | New modules written in this fork. `tg new-module <dir>` creates one. |
| `swift6_library` | Swift 6 mode, `-warnings-as-errors` | Existing Telegram modules that already compile cleanly in Swift 6 mode. The Swift 7 features are left out because they would need edits to Telegram's files. 14 modules so far (`git grep -l swift6_library`). |

To move more modules: run `tg strict-report`, pick modules with no problems that are not in its "not checked"
list, switch their `swift_library` to `swift6_library` (and drop the now-redundant `-warnings-as-errors` copt),
and run `tg build`. The report rebuilds all Swift code with the extra checks and replaces the normal outputs; the
next `tg build` restores them from the disk cache in about 20 seconds.

After an Xcode update, `xcrun swift-frontend -print-supported-features` lists new upcoming features to add to the
strict preset.

## Guardrails

`tools/dev/lint/` lints only the changed lines of Swift code with a pinned SwiftLint (force unwraps,
`try!`, `as!`, `Int32` timestamp arithmetic, narrowing conversions). It also has an opt-in pre-push
hook that runs the lint and the tests of the modules a push touches:

```sh
python3 tools/dev/lint/tglint.py install        # SwiftLint 0.65.1, checksum verified
python3 tools/dev/lint/tglint.py lint           # working tree vs HEAD
python3 tools/dev/lint/tglint.py install-hook   # pre-push: lint + affected tests
```

See [guardrails.md](guardrails.md) for the rules, the sanitizer test and the reasoning.

## Where the disk space goes

| Location | What | Controlled by |
| --- | --- | --- |
| The checkout | Sources, submodules, `.git` (~1 GB) | Shallow clone and submodules |
| Bazel output base (`bazel info output_base`) | Build outputs for every configuration you have built, plus `external/` | `tg clean` (outputs) / `tg prune` (everything) |
| `<output_base>/rules_xcodeproj.noindex` | A second output base used by builds started from Xcode | Same as above. Using mainly one of Xcode or the CLI avoids keeping two full sets of outputs. |
| `~/.cache/telegram-ios/bazel-disk-cache` | Content-addressed cache of action outputs | GC limits in `.bazelrc` / `user.bazelrc` |
| Repository cache (`bazel info repository_cache`) | Downloaded archives (`content_addressable/`) and extracted dependencies (`contents/`) | Shared by all Bazel projects of this user. Bazel deletes extracted dependencies unused for 14 days (`--repo_contents_cache_gc_max_age`); old archives stay until you delete them |
| `~/Library/Developer/Xcode/DerivedData/Telegram-*` | Xcode index and logs | `tg prune` |
| `~/.cache/telegram-ios/watch` | The watch app's DerivedData (~0.6 GB) and SwiftPM checkouts (~1.5 GB, mostly TDLib for every platform) | `tg watch clean` (DerivedData only) |

Each configuration you build (`debug_sim_arm64`, `release_arm64`, …) keeps its own output tree, so sticking to
one configuration for day-to-day work saves the most space.

## Keeping up with upstream

The repository has two long-lived branches:

- `upstream`: one commit per imported official release, each an exact snapshot of that tag (no upstream history).
- `main`: `upstream` plus this fork's changes.

To move to a new release:

```sh
tools/dev/tg sync-upstream release-13.2    # adds a snapshot commit to `upstream`
git switch main && git merge upstream
git submodule update --init --recursive --depth 1 --jobs 8
```

Expect conflicts in `MODULE.bazel`, `MODULE.bazel.lock`, `versions.json` and `.gitmodules` when upstream changes
dependencies. Keep whichever version is newer, keep the absolute submodule URLs and `shallow = true`, and if upstream
bumps `rules_apple` in its fork, check whether the patch in `build-system/patches/` still applies. For the lockfile,
take either side and let the next build rewrite it.

## Not changed, and why

- **Remote cache / remote execution.** The biggest speedup for a team, but it needs a server
  (e.g. [bazel-remote](https://github.com/buchgr/bazel-remote)). `Make.py --cacheHost=grpc://host:9092` already
  supports it; for a single machine, the bounded disk cache does the job.
- **BLAKE3 digests, skipping output checks, `--nobuild_runfile_links`.** Small or uncertain gains for this
  project, with real correctness or compatibility risk.
- **Swift index-while-building.** Already off for CLI builds (it isn't in rules_swift's default features);
  rules_xcodeproj enables it only for Xcode builds, where indexing is wanted.
- **Third-party binaries** (e.g. `RecaptchaEnterprise.xcframework` with visionOS slices, ~34 MB). Trimming them
  would diverge from upstream for little gain.
- **Bazel Central Registry modules for the script-built libraries** (dav1d, libwebp, opus, flatbuffers). FFmpeg's
  build script consumes dav1d and opus at fixed paths, FlatBuffers is pinned by URL and sha256, and with parallel
  `make` the remaining gain is small, while each switch risks behaviour differences in codec builds.
- **`swift.split_derived_files_generation`** (`Make.py --enableParallelSwiftmoduleGeneration`). Measured cold, with an
  empty cache: 1,071 s with it vs 756 s without (9,235 vs 7,775 actions, critical path 488 s vs 475 s). The extra
  derived-files action per module costs more CPU than the earlier start of dependents saves, even though only 5–6 of
  10 cores are busy during the last ~5 minutes of a cold build (the Swift module chain).
- **What is left on the critical path** is the chain of Swift modules from `AccountContext` to `TelegramUI`
  (~400 s cold, 36 s for `TelegramUI` alone). Shortening it means splitting modules, which is a code change.

## Parity with the macOS app

`docs/mac-core-paths.txt` lists what the Mac shares; `tools/dev/parity/parity.py` (identical in both repos) checks it.
`tools/dev/tg parity` (also run by `tg lint` without arguments) and the pre-push hook run only fast checks: every push
must be rooted at the import `b46f1ec6`, a pushed tgcalls/rlottie/tlottie pin must be on a `klaipher` remote, and a
push that touches shared paths prints a reminder to run `tools/dev/tg core-bump` on the Mac. Differences with the Mac
are warnings here; the Mac side enforces the lag limit, so an iOS hotfix never waits for a Mac build. The hook checks
only the pins the pushed commits change: a new branch is compared with the commit it leaves the remote's history at,
so a hotfix branch made from `origin/main` is never stopped by a pin that `origin/main` already carries. Only a
network URL under `klaipher/` counts as published (a local-path remote such as the Mac checkout does not). Skip once
with `TG_PARITY=0 git push`.

## Cache cleanup

Stale build caches clean themselves up after every build and test command, with no scheduled job: output bases of deleted worktrees, DerivedData, `.build` folders, merged worktrees, Instruments leftovers. See [cache-cleanup.md](cache-cleanup.md); `tools/dev/tg cache-cleanup --dry-run` shows what would go.
