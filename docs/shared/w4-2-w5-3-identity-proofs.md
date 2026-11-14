# W4.2 and W5.3 (iOS stage C): what was compared before the iOS copies were deleted

Nothing here was built or run; every comparison is a `cmp`, `diff` or blob comparison made at the parent commit of each commit.

## W4.2: tgcalls bridge and wasm script move into the fork

- Fork: klaipher/tgcalls `nanogram-shared` (local `nanogram-shared-next` 2a5daa0f14f89def3fd15179e30baca95b891c43).
- `cmp` of every moved file between the iOS tree (`submodules/TgVoipWebrtc/...`) and the fork's `ios/...`: identical for
  `Sources/OngoingCallThreadLocalContext.mm`, `Sources/MediaStreaming.mm`, `Sources/MediaUtils.h`, `tests/TestNegotiation.mm`,
  `PublicHeaders/TgVoipWebrtc/MediaStreaming.h`, `PublicHeaders/TgVoipWebrtc/OngoingCallThreadLocalContext.h`.
- `cmp submodules/TgVoipWebrtc/tools/wasm_to_source.py tgcalls/tools/wasm_to_source.py`: identical.
- A pure-Python check over the fork tree (`git ls-files`) found one `.cpp` under `tgcalls/` that the iOS BUILD does not
  name: `tgcalls/v2_4_0_0/Signaling_4_0_0.cpp` (not in the iOS BUILD before the merge either; not compiled, as before).

## W5.3: webrtc pin and the vendored third-party copies

- Fork: klaipher/webrtc `nanogram` fa0b3c5f69209ab4eb1b1976bc31b5818bbae687 (17 commits on 779c4aa7; `nanogram-security-fixes`
  is the same sha locally). Everything below was compared at the parent commit against the fork tree at that sha, or against
  the pristine upstream commit the fork pins (shallow fetch of the pinned commit into the session scratchpad).
- Pure-Python check: the iOS BUILD's source list (`nanogram/gen_build_lists.py ios third-party/webrtc/BUILD`, 1,284 files,
  equal to the fork's `nanogram/build-files/ios-bazel.txt`): every file exists in the fork tree (0 missing). Files the fork
  changed since 779c4aa7 that this list compiles are the absl_nonnull/absl_nullable edits, include hygiene and platform guards;
  the fork added only two C++ headers outside Android (`common_types.h`, `modules/audio_device/mac/audio_device_mac_options.h`).
- `third-party/webrtc/crc32c` (23 flat `src` files): all 23 blobs identical to google/crc32c 21fc8ef3 `src/`; the public header
  `crc32c.h` identical (`e8a78170`). `crc32c_config.h` is consumer-owned and moved byte-identical to
  `third-party/webrtc/config/crc32c/crc32c_config.h` (upstream only has `crc32c_config.h.in`).
- `third-party/webrtc/pffft` (20 files): all 20 blobs identical to the fork's `third_party/pffft`.
- `third-party/webrtc/rnnoise` (7 files, the Chromium rnnoise-vad extract): all 7 identical to the fork's `third_party/rnnoise`.
- `third-party/webrtc/fft4g/fft4g.cc`: equals the fork's `common_audio/third_party/ooura/fft_size_256/fft4g.cc` except that the
  fork adds `#include "common_audio/third_party/ooura/fft_size_256/fft4g.h"` (2 lines); the BUILD now compiles the fork's copy.
- `third-party/webrtc/libsrtp` (v2.2.0, trimmed, 71 files): replaced by cisco/libsrtp v2.5.0 (a566a9cf, the fork's gitlink).
  Of the 71 files 13 are identical to v2.5.0, 41 differ by the 2.2.0 -> 2.5.0 upstream changes, 17 do not exist in v2.5.0
  (Chromium additions `BUILD.gn`, `OWNERS`, `README.chromium`, `LIBSRTP_VERSION`, `codereview.settings`, `run_all_tests.sh`,
  `config/config.h`, and files upstream removed: `ekt.*`, `stat.c`, `ut_sim.*`, `getopt_s.h`, test drivers). Behaviour jump
  2.2.0 -> 2.5.0 is deliberate (ledger W0.5). The one `config.h` is the fork's `third_party/libsrtp_config/config.h`.
- `third-party/webrtc/absl` (Chromium snapshot 6bf3c73f, 1,446 files under `absl/`): replaced by the official abseil LTS
  20260817.0 (2065f4de, the fork's gitlink). 777 files identical, 626 differ (version change), 43 are old tests removed upstream.
  The local `attributes.h` lifetimebound edit is dropped (verify with a build; fallback: the fork's `nanogram/apply_abseil_workaround.sh`).
- `third-party/webrtc/dependencies` (usrsctp `ec55565693`, libevent 1.4.15 Chromium snapshot): not replaced. Nothing in the
  iOS BUILD compiles them (grep: only the `-I` flag and the excluded `*_libevent*.cc` names). usrsctp is dropped everywhere (ledger
  W0.5); libevent is carried in the fork's `third_party/libevent` for Android only.
