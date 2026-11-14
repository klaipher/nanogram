# Bazel build profiling (iOS)

Bazel writes a JSON trace profile for every command (`--generate_json_trace_profile`, default `auto`) to
`$(bazel info output_base)/command.profile.gz`. `.bazelrc` adds `--experimental_profile_include_target_label` and
`--experimental_profile_include_primary_output`, so each action event names its target and output. Neither flag is
part of the configuration, so the analysis cache survives them.
([profiling reference](https://bazel.build/rules/performance#performance-profiling),
[flag list](https://bazel.build/reference/command-line-reference))

## `tg profile`

```sh
tools/dev/tg build            # any build
tools/dev/tg profile          # copy, summarise, say where the trace is
tools/dev/tg profile --keep 20
tools/dev/tg profile --deep --release --device   # builds first, with extra profile events
```

- Copies the last profile to `build-output/profile/<timestamp>.gz` (git-ignored); the newest 10 stay (`--keep N`),
  older ones are deleted with their `.txt`. `cachegc`'s `build_output_logs` age covers leftovers.
- Runs `bazel analyze-profile` and saves its text next to the copy (`<timestamp>.txt`): phase times, the critical
  path, and the time per action type. This is Bazel's own output; the sections are not parsed.
- For the timeline open the `.gz` in <https://ui.perfetto.dev> (Open trace file). Action events carry the target label
  and primary output.
- `--deep` runs `tg build <options>` with `--experimental_profile_additional_tasks=worker_borrow,remote_cache_check,local_process_time`
  (via `TG_BAZEL_ARGS`, which `tg build` also honours on its own). The file is larger; use it when a plain profile
  does not explain an idle gap.

## Measuring the build-system changes

Compare before and after on the same machine, one change at a time, with an empty `--cacheDir` (or a fresh
`~/.cache/telegram-ios/bazel-disk-cache`) for cold numbers and a warm disk cache for the rest.

| Change | What to look at |
|---|---|
| Native genrules delete their scratch trees | `du -sh bazel-bin/third-party bazel-bin/submodules/ffmpeg` and `find bazel-bin/third-party -type f \| wc -l` after a build; only `Public/` outputs remain. `shasum -a 256 bazel-bin/third-party/*/Public/**/lib*.a` before and after: equal for an unchanged tool version. |
| CMake, Ninja and Meson extracted once (CMake 4.5.0, Ninja 1.13.2, Meson 1.6.0) | `bazel aquery 'mnemonic(Genrule, //third-party/...)' --output=text \| grep -c 'tar -xzf'` is 0 for the tool archives. Genrule time in `tg profile` drops by the extraction; compare `nm -gU`, `size` and `lipo -info` of each produced `.a` with the 4.1.2 build. |
| Ninja generator | Genrule wall time of `webp_build`, `libjxl_build`, `td_build` before and after; `ninja` shows in `--subcommands`. |
| `NANOGRAM_XCODE_ID` action env | `bazel aquery 'mnemonic(Genrule, //third-party/libvpx:libvpx_build)' \| grep NANOGRAM_XCODE_ID`; a second build runs 0 genrule actions; `--overrideXcodeVersion` with another Xcode re-runs them. |
| ThinLTO linker cache (release links) | `bazel aquery -c opt 'mnemonic(ObjcLink, //Telegram:Telegram)'` shows `-cache_path_lto`; two `release_arm64` builds with one `.cpp` touched between them: the second link action is much shorter in `tg profile`. `du -sh ~/.cache/telegram-ios/lto-cache`. |
| rules_rust pipelined compilation | Cold build before and after: Rust phase wall time, `Rustc` overlap and the critical path in `tg profile`/Perfetto. `nm -gU` and `size` of the wallet-engine and mtproto-engine static libraries must not change. Revert the `.bazelrc` line if the cold wall time does not improve. |

## Release optimization settings (build/release-opt)

| Setting | How to verify in the final build |
|---|---|
| wallet-engine Rust `-Copt-level=3` (was `z`) | `bazel aquery` with the `release_arm64` flags on `mnemonic(Rustc, //third-party/wallet-engine:*)` shows `-Copt-level=3` and `-Clto=fat` (also proves rules_rust `lto=fat` reaches `rust_static_library`). Time mnemonic-to-key on device before and after; compare `size -m` of TelegramUI or the app (expect tens of KB). Revert if there is no gain. |
| Watch app C packages `GCC_OPTIMIZATION_LEVEL=3` (was `-Os`) | In the watch compile DerivedData, the `*-common-args.resp` of COpus-t, COgg-t and WebPCore-t contain `-O3` and no `-Os`. Run OpusKitTests (PCM within 5.4e-7) and WebPDecodeParityTests. The thinned watch executable must stay well under 75 MB (about 34.5 MB per slice now): `lipo -thin` then `ls -l`. |
