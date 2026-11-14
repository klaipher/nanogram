# W1.1 identity proofs (shared-libraries plan)

Each vendored copy was replaced by a submodule of the single source. Proofs compare `git ls-tree -r` blob ids of the old
copy (`origin/main` 466d8350) with the new source. Nothing was built.

| Library | New source (pin) | Result |
|---|---|---|
| FFmpeg `submodules/ffmpeg/Sources/FFMpeg/ffmpeg-9.0.2` | klaipher/FFmpeg `nanogram` d84c50bc95ebde8a95c12c4f416a854b292a51f6 | 10399 old files: all identical except `libavcodec/hevc/hevcdec.c` (a3be41a4 -> bb79bf3a) and `libavutil/encryption_info.c` (a3eb955d -> 6fc3e338), the two Android fixes. 26 dotfiles added (BUILD glob excludes them). |
| boost_regex | boostorg/regex boost-1.92.0 7760ef2a | tree id of old `include/` = `HEAD:include` = 831656cc3fcada0d5cc0e9c081052bb64fa3ce1c |
| WAMR | bytecodealliance/wasm-micro-runtime WAMR-2.4.5 25bd7eb6 | 144 old `core/` blobs + LICENSE identical; every compiled glob matches the same file set (9 patterns) |
| ogg | xiph/ogg v1.3.6 be05b13e | bitwise.c, crctable.h, framing.c, ogg.h, os_types.h identical; generated config_types.h kept in `overlay/ogg/` |
| opusfile | xiph/opusfile v0.12 a55c164e | 6 files identical; 3 include-path edits (internal.h:32, opusfile.c:29, opusfile.h:110) replaced by BUILD `include_prefix` + `//third-party/opus:opus_flat_headers` |
| libwebp | webmproject/libwebp v1.6.0 4fa21912 | 333 of 334 identical; `gradlew.bat` differs in line endings only |
| td SharedHeaders | tdlib/td 0e88653d (existing pin) | 787 of 793 identical; 6 generated headers unused by `TdBinding.mm` |
| boringssl `aes_ige.c` | none | no reference anywhere (`git grep aes_ige`) |
| old Lottie renderer | none | already removed on origin/main (see CHANGELOG 13.2 202611121002 and NANOGRAM-CHANGES); the Watch app moved to tlottie later |

Open items: `submodules/OpusBinding/Sources/opusfile` is a second in-tree copy of opusfile (own sources, includes `opusfile/opusfile.h`),
not covered by this wave. The plan's "145 WAMR files" is 144 `core/` files plus LICENSE (BUILD excluded).

## Mac handoff for the W1.2 core bump (review findings)

Do these in the Mac core-bump commit:

- `submodules/CodeSyntax/CodeSyntax/CodeSyntax.xcodeproj/project.pbxproj` (lines ~349, ~387): HEADER_SEARCH_PATHS `.../third-party/boost_regex/include/` becomes `.../third-party/boost_regex/regex/include/`; update `tools/dev/tests/test_libprisma_shared.py:37` the same way.
- `scripts/configure_frameworks.sh` (~98-100): remove the td `sync-headers.sh` call into `third-party/td/TdBinding/SharedHeaders/td`; `tools/dev/nanogram/fwcache.py:43`: remove `TD_PAIR` (and any fwcache test expecting it). Otherwise every configure recreates 793 untracked files in the core submodule. The iOS `.gitignore` now also ignores that directory as a guard.
- After the bump run `swift package describe` in `third-party/td/TdBinding` (header path is now the in-package `td-headers`).
