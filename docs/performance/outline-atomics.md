# Outline atomics (SHARED-APPLE-CPU-1)

Opt-in: `TG_BAZEL_ARGS=--config=outline_atomics tools/dev/tg build ...`. Default off until measured.

## Why

`Telegram/BUILD` sets `minimum_os_version = "15.0"`, so clang compiles for `apple-a7` without LSE: every `std::atomic`
read-modify-write is an `ldaxr/stlxr` loop. `-moutline-atomics` emits calls to compiler-rt helpers (`___aarch64_ldadd4_acq_rel`
and friends, shipped in `libclang_rt.ios.a`) that use the LSE instruction when the CPU has it. Every iPhone that runs iOS 15 (A9 and
newer) either has LSE (A11 and newer) or takes the helper's LL/SC fallback, so **the device floor does not change**.

## What the config does

- `--copt=-moutline-atomics` for all C, C++ and Objective-C compiled by Bazel (target configuration).
- `--action_env=NANOGRAM_OUTLINE_ATOMICS=1`: the genrule libraries (td, opus, webp, libjpeg-turbo, libjxl, ffmpeg) append the flag to
  their own CFLAGS on iOS arm64 and simulator arm64 only (never x86_64 or macOS).
- Swift is untouched: `-Xcc` only reaches the Clang importer, and Swift/ObjC retain/release run in the OS runtime. dav1d and libvpx
  are not changed (meson crossfile and libvpx configure; add later if the measurement justifies it).

## Not covered, on purpose

- Watch app: prebuilt (`apple_prebuilt_watchos_application`, arm64_32); there is nothing to compile.
- Mac app: macOS 14 already targets `apple-m1` (LSE, dotprod); no flag needed. A raised iOS floor (16/17) would make
  `-mcpu=apple-a11/a12` the better choice and replace this config.

## Checks to run (not run by the author)

1. `python3 -m unittest tools.dev.tests.test_outline_atomics` (pure Python).
2. Device build with the config, then `otool -tv` on the app binary: `___aarch64_ldadd*` helpers should appear and link.
3. Instruments Time Profiler on an iPhone 12/13: video-call CPU and chat-list hitch ratio with and without the config. Expect a low
   single-digit percent change in call CPU; if it is not measurable, delete the config.
