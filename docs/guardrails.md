# Guardrails against shipping crashes

TestFlight build 202611011645 crashed at every launch. `peerPresenceStatusRefreshTimeout` computed
`statusTimestamp + 1` in `Int32`. The Telegram service account (777000) is "online until `Int32.max`",
Swift traps on overflow (`EXC_BREAKPOINT`), and the chat list lays that row out at launch. Fixed in
aee7088e. The trap itself worked as designed. Two things were missing: a test with the extreme value
the server really sends, and a check that flags 32-bit timestamp arithmetic in new code.

## What is in place

| Guardrail | Where | Run |
| --- | --- | --- |
| SwiftLint on changed lines only | `tools/dev/lint/swiftlint.yml`, `tools/dev/lint/tglint.py` | `python3 tools/dev/lint/tglint.py lint` |
| Opt-in git pre-push hook: lint the pushed lines, then run the tests of the touched modules | `tools/dev/lint/pre-push` | `python3 tools/dev/lint/tglint.py install-hook` |
| ASan + UBSan host test for the sparse DCT coefficient decoder (`SparseCoefficients.c`) | `//submodules/TelegramUI/Components/AnimationCache/ImageDCT:SparseCoefficientsSanitizerTests` | `tools/dev/tg test <label>` |
| A test that fails if a build file turns off Swift's runtime traps (`-Ounchecked`, `-remove-runtime-asserts`, ...) | `tools/dev/lint/tests/test_tglint.py` | `python3 -m unittest discover -s tools/dev/lint/tests` |
| The regression test for the crash | `PeerPresenceStatusManagerTests.testExtremeTimestampsDoNotOverflow` | `tools/dev/tg test //submodules/PeerPresenceStatusManager:PeerPresenceStatusManagerTests` |

### SwiftLint

SwiftLint 0.65.1 is pinned in `tglint.py` (release URL and sha256, the digest GitHub lists for
`portable_swiftlint.zip`). `tglint.py install` downloads it, checks the checksum and puts it in
`~/.cache/telegram-ios/tools/swiftlint-0.65.1/` (`TG_TOOLS_DIR` overrides the location). Homebrew is not
used, because it cannot pin an old version.

The code base is upstream-derived and large, so only **changed lines** are checked. `tglint.py`
finds them with `git diff -U0`, lints the changed files, and keeps the findings on those lines. With
`--commits A..B` it lints the files as committed in B, not the working tree. Vendored code under
`third-party/` is skipped.

Rules (`only_rules`, so none of SwiftLint's style rules run):

| Rule | Severity | Catches |
| --- | --- | --- |
| `force_unwrapping`, `force_try`, `force_cast` | error (warning in `Tests/`) | `x!`, `try!`, `as!` |
| `int32_timestamp_arithmetic` (custom) | error | `until + 1`, `lastActivity + 30`, `Int32(...) + 30`: a timestamp-like name, or an explicit `Int32(...)`, followed by `+`, `-` or `*` and an integer literal |
| `narrowing_integer_conversion` (custom) | warning | `Int32(x)`, `UInt8(x)`, ... without `clamping:`, `exactly:` or `truncatingIfNeeded:`. They trap when the value does not fit, or when it is NaN or infinite. |
| `implicitly_unwrapped_optional`, `unowned_variable_capture` | warning | `T!` declarations, `[unowned x]` |

The timestamp rule is a regex, so it cannot see types. To keep it precise, `tglint.py` drops a match
when the name is declared earlier in the same file as `Int`, `Int64`, `Double` or another wide type,
for example `let until = Int64(until)`. The check is per file, not per scope. If a match is still
wrong, put `// swiftlint:disable:this int32_timestamp_arithmetic` on the line. Checked against the
crashing commit 2c51ac0d, it flags the three `Int32` additions on changed lines
(`until(statusTimestamp + 1)`, `+ 31`, `activeUntil + 1`). The fixed file passes. On all of today's
commits it found 15 blocking findings, almost all of them force unwraps.

`--strict` (or `TG_LINT_STRICT=1` for the hook) makes warnings block too.

### pre-push hook

`install-hook` writes a small `pre-push` into the hooks directory that git uses
(`git rev-parse --git-path hooks`, shared by all worktrees). That hook runs the
`tools/dev/lint/pre-push` of whichever checkout is pushing. The installer does not replace a hook it
did not write. `install-hook --uninstall` removes it.

For each pushed ref the hook:

1. lints the lines the push adds (from the remote's commit, or for a new branch, from where it
   leaves what the remote already has), and stops the push on any error;
2. maps the changed paths to test targets: the `ios_unit_test` / `swift_test` / `cc_test` rules in
   each changed file's nearest `BUILD`, plus tests in other packages whose test or `testonly`
   library names the package directly. Tests from other packages are added only when there are at
   most 3 of them (Postbox and TelegramCore have 14 and 23). `TG_PRE_PUSH_ALL_TESTS=1` runs them all.
   A package with no such tests falls back to its direct dependents' tests;
3. runs them one at a time with `tools/dev/tg test <label>`, and runs the Python suites when
   `tools/dev/lint/` or `build-system/Make/` changed.

Tests run on the working tree. The hook warns when the working tree has uncommitted changes.
`TG_PRE_PUSH_TESTS=0 git push` lints only, `TG_PRE_PUSH=0` turns the hook off, and
`git push --no-verify` skips it once. `python3 tools/dev/lint/tglint.py affected-tests [paths]` prints
the mapping.

### Sanitizers

`SparseCoefficientsSanitizerTests` is a host `cc_test`. It compiles `SparseCoefficients.c` with
`-fsanitize=address,undefined -fno-sanitize-recover=all` (UBSan only reports and goes on unless
recovery is off). It round-trips every length from 0 to 70 at four densities, rejects every
truncated and over-long encoding, and decodes 200,000 random inputs. Buffers are allocated at their
exact size, so ASan reports a one-byte overrun. The flags apply to the test binary only. Four of
five hand-made decoder bugs (an off-by-one max length, a missing bounds check in either loop, a
16-byte NEON load near the end) fail it with `heap-buffer-overflow`. The fifth, removing the
trailing-mask check, behaves the same as the original, because the final `offset == sourceLength`
check rejects that input anyway.

## Compiler and test options

- **Overflow traps stay on.** Swift's arithmetic operators "don't overflow by default. Overflow
  behavior is trapped and reported as an error" ([The Swift Programming Language: Advanced
  Operators](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/advancedoperators/#Overflow-Operators)).
  `-Ounchecked` would "remove runtime safety checks" (`swiftc --help`, Swift 6.4.2). The build would
  then keep running with a wrapped value instead of crashing. Release builds use `-O` with whole-module
  optimization (`build-system/Make/Make.py`), which keeps the checks. Nothing in the repository uses `-Ounchecked` or `-remove-runtime-asserts`, and
  `OverflowTrapsStayOnTests` keeps it that way. A trap ends the process at the bug, and its crash
  report points at that line ([Addressing crashes from Swift runtime
  errors](https://developer.apple.com/documentation/xcode/addressing-crashes-from-swift-runtime-errors)).
  Wrapping operators (`&+`) are not a fix for timestamps: they hide the bug.
- **Warnings as errors** are already on for 723 of 732 modules and for every new module
  (`strict_swift_library`, see `docs/local-development.md`, "Swift strictness").
- **ASan/UBSan for C and Objective-C** are on for host `cc_test`s like the one above. That is cheap,
  because it compiles only the unit under test. For an `ios_unit_test`, apple_support, rules_swift and
  rules_apple support `--features=asan` / `--features=ubsan` (rules_apple bundles the clang runtime
  into the test). That rebuilds the test's whole dependency graph instrumented, and `tg test` cannot
  pass Bazel flags. This is not set up and not verified; it would be
  `Make.py --bazelArguments="--features=asan --features=ubsan --copt=-fno-sanitize-recover=all" test --target ...`.
  Apple's overview: [Diagnosing memory, thread, and crash issues
  early](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early).
  Clang: [UndefinedBehaviorSanitizer](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html).
- **Swift strict concurrency** does not cover overflow or force unwraps. It is already on for new
  modules. Moving existing modules is tracked through `tg strict-report`.
- **Tests with server extremes.** Values that come from the server (`Int32` timestamps, ids,
  counts) should be tested with `Int32.max`, `Int32.min` and 0. The server really sends them:
  "online forever" is `Int32.max`.

## Not done (proposals)

- `tg lint`: one line in `tools/dev/tg` (owned elsewhere, not edited here):
  `lint) python3 "$ROOT/tools/dev/lint/tglint.py" lint "$@" ;;`, and the same tool behind
  `tg testflight` before it uploads: `python3 "$ROOT/tools/dev/lint/tglint.py" lint --commits <last shipped>..HEAD`.
- `Make.py test` takes one `--target`. Accepting several would let the hook run all its tests in one
  Bazel invocation instead of one `Make.py` run per target.
- A launch smoke test before every TestFlight upload: install the release build on a simulator that
  is logged in to a test account, launch it, and fail when the process exits within 20 s.
- Launch crash recovery in the app: see below.

### Design: recovering from repeated launch crashes (no code yet)

Detection. Early in `application(_:didFinishLaunchingWithOptions:)`, before Postbox opens, write
`{ build, attempt += 1 }` to a small file in the app group container. Reset `attempt` to 0 once the
app has stayed in the foreground for 10 s after the root controller appeared, or when it goes to
background normally. If `attempt >= 3` for the same build at the next start, the last launches died
early. Nothing needs to be caught at crash time, so this also covers `EXC_BREAKPOINT` traps that no
signal handler can survive. MetricKit's `MXCrashDiagnostic`
([docs](https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic)) arrives later and can
confirm the cause in logs, but it is not fast enough to make the decision.

Recovery, least destructive first, one step per further failed launch:

1. Safe mode for fork features: turn off the fork's own runtime flags (new caches, presence timer
   changes, experimental UI) and fall back to upstream code paths where a flag exists. Show a small
   banner that offers to send logs.
2. Drop derived caches that are rebuilt on demand, such as the animated emoji and sticker cache
   (`DCTAnimationCacheImpl` files). Never touch the Postbox database, keys or drafts.
3. Open with the chat list empty (no row layout) and load it after the first frame, so a bad row
   cannot block launch.

Risks:

- False positives. A user who kills the app three times during launch, or iOS watchdog kills on a
  slow device, would trigger recovery. Steps 1 and 2 only cost cache rebuilds, so they are safe to
  get wrong.
- The detector itself must not crash or block: one small file, no Postbox, no locks shared with the
  extensions. The notification service extension has its own launches, so the counter must belong to
  the main app only.
- Safe mode can hide a bug. Every recovery must be logged and reported, and safe mode must reset on
  the next build, or a crash that recovery covers can stay unfixed.
- Crashes that happen before the counter is written, in `main` or static initializers, are not
  covered.
- A crash in Postbox data (a bad row stored in the database) survives cache resets. Only a targeted
  fix helps there; deleting the database is not an acceptable recovery.
