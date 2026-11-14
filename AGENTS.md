# AGENTS.md

Nanogram for iOS: an unofficial Telegram-iOS fork (klaipher/nanogram), also the shared core of Nanogram for macOS
(`../nanogram-macos` consumes it through `submodules/telegram-ios`). This file holds what every session must know.
Everything else is in `docs/`, indexed in [docs/README.md](docs/README.md). `CLAUDE.md` only imports this file.

## Repo map

- `Telegram/` app target, extensions, watch app. `submodules/` our libraries (TelegramCore, Postbox, TelegramUI, ...).
  `third-party/` vendored code. `build-system/` Bazel and `Make.py`. `tools/dev/` our tooling (`tg`, lint, parity, cachegc).
- Submodule forks: tgcalls, webrtc (both `klaipher/*`). Upstream imports land on the `upstream` branch only.
- Shared with the Mac: `docs/mac-core-paths.txt`, checked by `tools/dev/parity/parity.py` (a wrapper; the tool, the manifest `shared-libraries.json`, `check_shared.py`, the cache policy and the shared docs live in the `shared/` submodule, klaipher/nanogram-deps).
- Which features exist on iOS, on the Mac and in official Telegram, and what is still open: [`shared/feature-parity.md`](shared/feature-parity.md) (one copy for iOS, Mac and Android in the `shared/` submodule; update the matching row when a feature lands).

## Hard rules

- Marketing version follows upstream; only the build number changes. Never fetch upstream tags/branches by hand (`tg sync-upstream`).
- A fix in shared code (core, tgcalls, webrtc, libprisma) lands on both apps in the same round.
- A fix in shared native code lands in the single source (an official pin or ONE klaipher fork branch listed in `shared/shared-libraries.json`), then all three pins (iOS, Mac, Android) move the same day. No vendored copies, no per-platform branches; `tools/dev/native/check_shared.py` runs in the pre-push hook.
- Never `--no-verify`. Never read `~/.config/telegram-ios`, keychains or signing material. No scheduled jobs.
- Agents do not build or launch the app (no `tg build/test/run`, `bazel build/test`, `xcodebuild`); one combined build at the end of a round, by the owner's pipeline. Pure-Python tests are fine.
- Work in your own worktree and branch under `~/Projects/wt/`, never in the main checkout.
- Swift traps on overflow and bad casts: no force unwraps/`try!`/`as!` and no 32-bit timestamp arithmetic in new code (`docs/guardrails.md`).
- Visual changes are judged from recorded frames, not from a green build (`docs/visual-verification.md`).

## Development pipeline (full text: [shared/development-pipeline.md](shared/development-pipeline.md))

1. Research and review in parallel lenses, with evidence. 2. Adversarial verification of every finding.
3. Fix confirmed findings on branches, tests first. 4. No builds by agents. 5. One combined build per platform at the end.
6. Fix what the build shows. 7. Push through the hooks. 8. Report: findings with evidence, decisions with trade-offs, open questions.

## Change records (see [docs/fork-records.md](docs/fork-records.md))

Every change that alters behaviour updates `CHANGELOG.md` (`## Unreleased`: what and how, with commit) and, when it
changes how we differ from upstream, `NANOGRAM-CHANGES.md`. A fork submodule change also needs the fork's own records.
Public notes (releases repo, appcast) are short and say which part got better, never how. The pre-push hook warns when a
push of product code touches neither file.

## Disk and worktrees

Output bases, DerivedData and SwiftPM scratch are per checkout (8-29 GB each). Stop a worktree's Bazel server and
`git worktree remove` it when done, then `tools/dev/tg cache-cleanup`. `tg disk` shows usage. Details in the pipeline doc and
`docs/cache-cleanup.md`.

## Commands (all via `tools/dev/tg`; run `tg help`)

`setup`, `doctor`, `build`, `run`, `test [label]`, `lint`, `parity`, `disk`, `cache-cleanup`, `device`, `testflight --notes <file>`,
`sync-upstream <tag>`. Full build and test invocations, codesigning env and host-only `bazel test` targets: [docs/build-and-test.md](docs/build-and-test.md).

## Where things are

Start from [docs/README.md](docs/README.md). The most used: build and test (`docs/build-and-test.md`), simulator
(`docs/simulator.md`), code style (`docs/code-style-and-structure.md`), per-subsystem invariants (`docs/subsystems/`),
performance rules (`docs/performance/`), compiler pitfalls (`docs/compiler-pitfalls-swift-6-4.md`), calls
(`docs/subsystems/tgcalls.md`, `submodules/TgVoipWebrtc/CLAUDE.md`). Read the matching doc before touching a subsystem.
