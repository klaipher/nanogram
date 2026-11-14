# W2.I1 identity proofs (iOS)

How each swap of a vendored copy for the single source was checked. Nothing was built; the proofs are blob and tree
comparisons made before the old copy was deleted.

## openh264

- Old copy: `third-party/openh264/third_party/openh264/src` (432 files).
- New source: submodule `third-party/openh264/openh264` = klaipher/openh264 `nanogram` 3583f617
  (v2.7.0 1bca6231 + "H.264 levels 6.0, 6.1 and 6.2" + "subcodec sprite mode (bSubcodecMode, default off)").
- `git diff --stat v2.7.0 nanogram` in the fork lists exactly 12 files (91 insertions, 11 deletions).
- `diff -rq <old copy> <fork checkout> -x .git` reports no differing file and no file that exists only in the old copy:
  all 432 vendored files are byte-identical to the fork tree (the fork has more, upstream tests and docs).
- BUILD: every `third_party/openh264/src/` path became `openh264/`; the four public API headers keep their include
  path `third_party/openh264/src/codec/api/wels/*.h` through `include_prefix` / `strip_include_prefix`.

## rnnoise

- Old copy: `third-party/rnnoise/{Sources,PublicHeaders,COPYING}` (xiph v0.2 + 3 patches).
- New source: submodule `third-party/rnnoise/rnnoise` = klaipher/rnnoise `nanogram` d2d79970 (v0.2 904a876d + portability
  headers, denoise.c hardening, trimmed `rnnoise_data.c/h`).
- `cmp` of every old file (29 files under Sources/ and Sources/x86/, `PublicHeaders/rnnoise.h`, `COPYING`) against the fork's
  `src/`, `include/rnnoise.h` and `COPYING`: no difference. The fork has 5 extra tool files (dump_features.c,
  dump_rnnoise_tables.c, write_weights.c, compile.sh, rnn_train.py), which the BUILD excludes.
- The three symbol renames (`compute_rnn`, `eband20ms`, `init_rnnoise` to `rnnoise_*`) stay in the BUILD copts.

## libprisma

- Old copy: `third-party/libprisma/{Sources,Resources,include}` (iOS 94640c63 + TokenizeStats/TokenizeLimits; Syntaxer.mm for iOS).
- New source: submodule `third-party/libprisma/libprisma` = klaipher/libprisma `nanogram` c061944d (94640c63 + bounded
  tokenizing incl. TokenizeStats/TokenizeLimits, one `apple/Syntaxer` for iOS and macOS, alias joining in generate.js).
- `cmp`: LanguageTree.{cpp,h}, TokenList.{cpp,h}, UnicodeEscapes.h and `grammars.dat` are byte-identical to the fork's
  `libprisma/`. Highlight.{h,cpp} and SyntaxHighlighter.{h,cpp} differ only by the additions of the Android budget work
  (BudgetedPosition, repeat-count specialization, weak tree pointers, `search()`, `searchesToGiveUp`); the iOS-side hunks
  (TokenizeStats, TokenizeLimits, the two caps) are all present, which is why the host test still compiles unchanged.
- `Syntaxer.mm` and `Syntaxer.h`: the iOS file differs from the fork's `apple/Syntaxer.mm` by the `SyntaxerColor/SyntaxerFont`
  platform aliases, the macOS `themeKeys` initializer and `static` helpers (the merged iOS+macOS version).
- `Tests/SyntaxHighlighterRecursionTests.cpp` stays in this repository; its BUILD target reads the submodule files.

## sqlcipher-amalgamation

- Old copy: `submodules/sqlcipher/{Sources/sqlite3.c,PublicHeaders/sqlcipher/*.h}` (SQLCipher 4.20.0 / SQLite 3.54.1).
- New source: submodule `submodules/sqlcipher/amalgamation` = klaipher/sqlcipher-amalgamation `nanogram` 9948d5af
  (tag `v4.20.0-nanogram1`), which is this copy byte for byte.
- `cmp`: `sqlite3.c` and the three headers (`sqlite3.h`, `sqlite3ext.h`, `sqlite3session.h`) are identical to the fork's
  `sqlite3.c` and `headers/sqlcipher/*.h`.
- BUILD and Package.swift keep every `-D` define; the `<sqlcipher/sqlite3.h>` include path is unchanged
  (`includes = ["amalgamation/headers"]`).

## wallet-engine

- Old pin: i582/wallet-engine e59e0d89 ("refactor: encrypted comments key check"). New pin: klaipher/wallet-engine
  `nanogram` 44ae85c7 = e59e0d89 + 5 commits (TON Connect envelope encrypt/decrypt, NFT transfer preparation, key
  rotation preview and both delivery forms from the Android fork 5c65e47c; the recipient-key check stays on by default,
  `trust_recipient_public_key` is an opt-in field).
- `git diff e59e0d89 44ae85c --stat` in the fork: 17 files, no change to `Cargo.toml`/`Cargo.lock` (MODULE.bazel crate specs
  and the `Cargo.Bazel.lock` files stay valid) and no new `.rs` file (the BUILD globs are unchanged).
- iOS callers: the new `trustRecipientPublicKey` fields are UniFFI records with `default = false`, so the generated Swift
  initialisers keep working for `CreateEncryptedCommentRequest` and `EncryptedCommentRecipientRequest`
  (`WalletEngineRuntime.swift` passes neither). The iOS behaviour (key verified) is unchanged.

## libyuv

- Old copy: `third-party/libyuv/third_party/libyuv` (197 files, version 1977).
- New source: submodule at the same path = klaipher/libyuv `nanogram` 947f5326 = upstream 0b8dd231 (version 1977,
  2026-10-29) + one commit that deletes `BUILD.bazel`, `WORKSPACE.bazel` and `libyuv.bzl` + the fork records.
- Proof: `git ls-tree -r` blob ids of the old copy against `0b8dd231` fetched from chromium.googlesource.com: 0 differing
  blobs, 0 files only in the old copy; upstream has 6 more files (`.clang-format`, `.gitignore`, `.gn` and the three Bazel
  files). The BUILD is unchanged: the path is the same.
- S1 spike (Bazel 9, decided by reading the docs, nothing run): a directory with a `BUILD.bazel` is its own package and its
  files cannot be labelled from the parent package; recursive globs stop there. A root `MODULE.bazel` or `WORKSPACE.bazel`
  is also a repository boundary marker. Upstream libyuv ships BUILD.bazel + WORKSPACE.bazel, BoringSSL ships BUILD.bazel +
  MODULE.bazel (+ `.bazelignore`, which Bazel reads only at the main repository root). `new_local_repository(build_file=)`
  would need the dependency to become an external repository, and the docs do not say what happens to the upstream root
  BUILD.bazel that the rule symlinks in, so that route is unproven. The plan's fallback (a one-commit klaipher fork that
  deletes the Bazel files) is used for libyuv; BoringSSL is deferred (see the lane report).

## Handoff for the Mac (W2.I2 core bump) and Android (W2.I3)

Mac, after the core bump:
- `docs/mac-core-paths.txt` and `tools/dev/native/native-libs.json` are copied byte for byte from the iOS commit.
- openh264: `core-xprojects/OpenH264/OpenH264/build.sh` builds from `submodules/telegram-ios/third-party/openh264/openh264`
  (rsync into build/, no clone); native-libs probe `third-party/openh264/openh264/codec/api/wels/codec_ver.h`.
- rnnoise: the pbxproj group paths become `third-party/rnnoise/rnnoise/{include,src}` and exclude `src/dump_features.c`,
  `src/dump_rnnoise_tables.c`, `src/write_weights.c`; update the `configure_frameworks.sh` symlink.
- libprisma: `CodeSyntax` compiles the shared `libprisma/apple/Syntaxer.mm` and the fork's `libprisma/libprisma/*.cpp`, uses
  `libprisma/libprisma/grammars.dat`, defines `BOOST_REGEX_MAX_BLOCKS=1536`, and deletes its own Syntaxer copy.
- sqlcipher: the Package.swift of `submodules/sqlcipher` already reads `amalgamation/`; no Mac file moves.
- OpusBinding: its Package.swift reads ogg and opusfile through `SwiftPMLinks/` symlinks; `tools/tests/audio-trim-store`
  must use `third-party/ogg/ogg/include` plus `third-party/ogg/overlay` and `third-party/opusfile/opusfile`.
- wallet-engine: regenerate `ffi-availability.txt` and the bindings (`scripts/check-wallet-engine-bindings.sh`).
- libyuv: the Mac keeps tg_owt's nested copy until W5.

Android:
- The `shared/` pin is the manifest commit 7d5bd332; `check_shared.py --side android` fails on the old pins of openh264,
  rnnoise, libprisma, sqlite (no sqlcipher-amalgamation yet), wallet-engine and libyuv until they move to the manifest
  commits. Android's libprisma must run `generate_prisma_grammars.sh` with `PRISMA_JOIN_ALIASES=1`.

Deferred in the iOS integrator stage: BoringSSL (see the S1 note above: a klaipher/boringssl fork without BUILD.bazel,
MODULE.bazel and `.bazelignore` is needed first, and the BUILD move from 2ea3200c to 0.20261105.0 must be built).
