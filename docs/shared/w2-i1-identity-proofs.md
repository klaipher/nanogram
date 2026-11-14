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
