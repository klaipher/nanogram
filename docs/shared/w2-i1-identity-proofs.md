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
