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
| `tg build --full` | debug, simulator, with the Share/Notification/Intents/Widget extensions |
| `tg build --release` | optimized simulator build (for profiling) |
| `tg build --device` | debug device build (needs real provisioning profiles; set `TG_CODESIGNING`) |
| `tg test //submodules/TextFormat:TextFormatTests` | one test target |
| `tg disk` / `tg clean` / `tg prune --yes` | inspect / trim / wipe build state |

The app is at `bazel-bin/Telegram/Telegram.ipa`. To run it in a simulator, unzip it and
`xcrun simctl install <udid> Payload/Telegram.app`.

## Measured results

Debug simulator build without extensions (`tg build`) on a 10-core Apple silicon Mac with 32 GB RAM, Xcode 27.2.

| | Upstream setup (Bazel 9.2) | This fork |
| --- | --- | --- |
| Cold build | 17 min 51 s | 19 min 24 s (critical path 720 s vs 715 s: same work, run-to-run noise) |
| No-op rebuild (`tg build` again) | 4.5 s (Bazel 2.4 s, re-analyzes 8,125 targets) | **1.8 s** (Bazel 0.3 s, nothing re-analyzed) |
| One Swift file changed (comment) | | 8.7 s |
| Bazel outputs + disk cache, actual disk used | ~22.5 GB | **~14.2 GB** (the 7.4 GB disk cache shares blocks with the outputs) |

`du` reports the disk cache at full size either way, because it counts copy-on-write clones twice; the numbers above
come from the change in free space. Downloaded archives (the repository cache) add 3–6 GB, shared with other Bazel
projects on the machine.

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
| Fixed `Make.py --bazelArguments` | `build-system/Make/Make.py` | The flag was parsed but silently dropped. It now reaches `build`, `test`, `query` and `generateProject` (last, so it can override defaults). |

### Less disk space

| Change | Where | Effect |
| --- | --- | --- |
| Bazel 9.3: copy-on-write disk cache | `versions.json` | Disk cache entries are APFS clones of the build outputs instead of second copies: ~8 GB saved on a debug build. |
| Disk cache garbage collection: 40 GB cap, 14-day max age | `.bazelrc` | Upstream passes `--disk_cache` with no limit, so it grows forever. Bazel now trims it in the background when idle. Change the limits in `user.bazelrc`. |
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

Not updated: the gazelle 2.0 line (betas only). `rules_apple` and `rules_xcodeproj` use `archive_override` because
the versions needed are not in the Bazel Central Registry yet; switch them to plain `bazel_dep` versions once they are.

### Fork hygiene

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

## Where the disk space goes

| Location | What | Controlled by |
| --- | --- | --- |
| The checkout | Sources, submodules, `.git` (~1 GB) | Shallow clone and submodules |
| Bazel output base (`bazel info output_base`) | Build outputs for every configuration you have built, plus `external/` | `tg clean` (outputs) / `tg prune` (everything) |
| `<output_base>/rules_xcodeproj.noindex` | A second output base used by builds started from Xcode | Same as above. Using mainly one of Xcode or the CLI avoids keeping two full sets of outputs. |
| `~/.cache/telegram-ios/bazel-disk-cache` | Content-addressed cache of action outputs | GC limits in `.bazelrc` / `user.bazelrc` |
| Repository cache (`bazel info repository_cache`) | Downloaded archives | Shared by all Bazel projects of this user; old versions stay until you delete it |
| `~/Library/Developer/Xcode/DerivedData/Telegram-*` | Xcode index and logs | `tg prune` |

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
