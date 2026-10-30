# Local development

This fork tracks the official Telegram-iOS releases (currently **release-13.1.1**) with a small set of changes
that make local builds faster and keep disk usage bounded. This page explains what was changed and why, and
how to work with the fork day to day.

## Quick start

```sh
git clone https://github.com/klaipher/telegram-ios-dev.git && cd telegram-ios-dev
tools/dev/tg setup        # git tuning, shallow submodules, local config files
# put your own api_id / api_hash in build-system/dev-configuration.json
tools/dev/tg doctor       # checks Xcode (27.1, see versions.json), config, submodules, free disk
tools/dev/tg project      # generate + open the Xcode project (simulator, no extensions)
tools/dev/tg build        # or build from the command line (debug simulator, no extensions)
```

Requirements: macOS 27, Xcode **27.1** selected with `xcode-select`, and roughly 40–60 GB free for the first full
debug build (Bazel outputs plus the disk cache). Simulator builds need no Apple developer account: they use
`build-system/fake-codesigning` with provisioning profiles disabled, the same setup upstream's own CI uses.

`tools/dev/tg help` lists everything. Common variants:

| Command | What it builds |
| --- | --- |
| `tg build` | debug, simulator, app only (fastest) |
| `tg build --full` | debug, simulator, with the Share/Notification/Intents/Widget extensions |
| `tg build --release` | optimized simulator build (for profiling) |
| `tg build --device` | debug device build (needs real provisioning profiles; set `TG_CODESIGNING`) |
| `tg test //submodules/TextFormat:TextFormatTests` | one test target |
| `tg disk` / `tg clean` / `tg prune --yes` | inspect / trim / wipe build state |

## How the build system works (upstream)

- **Bazel 9.2.0 with Bzlmod** (`MODULE.bazel`, lockfile checked in). The pinned binary is downloaded by
  `build-system/Make/Make.py` into `build-input/` and verified against the sha256 in `versions.json`.
- `Make.py` is the entry point. It reads a JSON configuration (bundle id, api id, team id), resolves
  codesigning, and calls Bazel with the right flags for one of four configurations: `debug_sim_arm64`,
  `debug_arm64`, `release_sim_arm64`, `release_arm64`.
- Apple rules (`rules_apple`, `rules_swift`, `apple_support`, `rules_xcodeproj`) are vendored as git submodules
  under `build-system/bazel-rules` and wired in with `local_path_override`.
- Xcode integration is `rules_xcodeproj` (BwB mode): Xcode drives Bazel, so the Xcode project and the CLI share
  the same build graph.
- Rust (MTProto engine, wallet engine) builds through `rules_rust` with every crate and toolchain archive pinned
  by checksum; Go is used only for a test tool.

The upstream setup is already in good shape: single-architecture builds, a Swift persistent worker,
`swift.cacheable_swiftmodules`, the global module cache, path remapping so outputs are cacheable, deterministic
archives (`ZERO_AR_DATE`), and `-Osize` + WMO + dead stripping only in release. The changes below target what is
left: unbounded disk growth, slow no-op builds, work that most local changes don't need, and a few rough edges
for a fork.

## What this fork changes

### Faster builds

| Change | Where | Effect |
| --- | --- | --- |
| Skip the 5 app extensions by default (`--//Telegram:disableExtensions`) | `tools/dev/tg build` / `project` | Share, Notification Service/Content, Intents and Widget are separate binaries that most UI work never touches. Less to compile and link on every build. `--full` brings them back. |
| `--watchfs` | `.bazelrc` | Bazel uses FSEvents instead of re-checking ~49k source files at the start of each build: faster no-op and small incremental builds. |
| `core.fsmonitor`, `core.untrackedCache`, `feature.manyFiles` | `tg setup` (local git config) | Fast `git status` / `git diff` on a ~49k-file checkout. |
| Shared, persistent disk cache by default (`~/.cache/telegram-ios/bazel-disk-cache`) | `tools/dev/tg` | Switching branches or running `bazel clean` reuses earlier outputs instead of rebuilding them. Shared between the CLI and the generated Xcode project. |
| Fixed `Make.py --bazelArguments` | `build-system/Make/Make.py` | The flag was parsed but silently dropped. It now reaches `build`, `test`, `query` and `generateProject` (last, so it can override defaults). Covered by `build-system/Make/tests/test_bazel_arguments.py`. |

### Less disk space

| Change | Where | Effect |
| --- | --- | --- |
| Disk cache garbage collection: 40 GB cap, 14-day max age | `.bazelrc` | Upstream passes `--disk_cache` with no limit, so it grows forever. Bazel now trims it in the background when idle. Change the limits in `user.bazelrc`. |
| `--experimental_repository_cache_hardlinks` | `.bazelrc` | Downloaded archives (Rust and Go toolchains, CMake, wasi-sdk, crates) are hardlinked into `external/` instead of copied. |
| Shallow submodules (`shallow = true` in `.gitmodules`) | `.gitmodules` | `git submodule update` fetches one commit per submodule instead of its whole history (~400 MB more for webrtc, libvpx and td alone). |
| History-free repository | git layout (below) | One snapshot commit per upstream release instead of upstream's full history: ~130 MB of git objects instead of ~890 MB. The whole checkout with submodules is ~1 GB, of which `.git` is ~230 MB. |
| `tg disk`, `tg clean`, `tg prune` | `tools/dev/tg` | See where space goes (checkout, output base, the Xcode project's nested output base, disk cache, repository cache, DerivedData) and reclaim it. |

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
  only. `sanity.yml` runs on Linux in under a minute: the `Make.py` unit tests, shellcheck, and the version-pin check.

All changes to upstream files are small and additive, so upstream merges stay easy.

## Where the disk space goes

| Location | What | Controlled by |
| --- | --- | --- |
| The checkout | Sources, submodules, `.git` (~1 GB) | Shallow clone and submodules |
| Bazel output base (`bazel info output_base`) | Build outputs for every configuration you have built, plus `external/` | `tg clean` (outputs) / `tg prune` (everything) |
| `<output_base>/rules_xcodeproj.noindex` | A second output base used by builds started from Xcode | Same as above. Using mainly one of Xcode or the CLI avoids keeping two full sets of outputs. |
| `~/.cache/telegram-ios/bazel-disk-cache` | Content-addressed cache of action outputs | GC limits in `.bazelrc` / `user.bazelrc` |
| Repository cache (`bazel info repository_cache`) | Downloaded archives | Shared by all checkouts of this user |
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

Merge conflicts, if any, will be in the few files listed above. If upstream changes `.gitmodules`, keep the
absolute URLs and `shallow = true`.

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
