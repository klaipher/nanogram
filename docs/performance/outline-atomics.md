# Outline atomics (SHARED-APPLE-CPU-1): BLOCKED

Status: resolved by the iOS 26.0 floor (2026-11-14). The `--config=outline_atomics` opt-in stays withdrawn and is no longer needed. Section "Why it was proposed" onward is the history for the old floor.

## Resolution

`Telegram/BUILD` sets `minimum_os_version = "26.0"`. Apple clang and swiftc then default to `apple-a12` (no `-mcpu` flag needed): LSE atomics (`__ARM_FEATURE_ATOMICS`), CRC32, RCPC, FP16, JSCVT. `std::atomic` read-modify-write and Swift/ObjC refcounts compile to inline `ldadd`/`cas`, with no helper calls. Do not pass `apple-a13`: A12 iPads lack dotprod and sha3. Rust gets `-Ctarget-cpu=apple-a12` through `.bazelrc`. `tools/dev/tests/test_outline_atomics.py` asserts the inline code at the floor.

Old status: blocked, a device build with `-moutline-atomics` for an older floor does not link.

## Why it was proposed

`Telegram/BUILD` set `minimum_os_version = "15.0"`, so clang compiled for `apple-a7` without LSE: every `std::atomic`
read-modify-write is an `ldaxr/stlxr` loop. `-moutline-atomics` would call compiler-rt helpers that use the LSE instruction when the
CPU has it (A11 and newer) and a LL/SC fallback otherwise, so the device floor would not change.

## Why it is blocked

Reproduced with Apple clang 21.0.0: `xcrun -sdk iphoneos clang++ -target arm64-apple-ios15.0 -O2 -moutline-atomics` on a
`std::atomic<int>::fetch_add` emits `bl ___aarch64_ldadd4_acq_rel` (Mach-O adds a leading underscore to `__aarch64_...`, giving three).
Xcode's `libclang_rt.ios.a` defines `__aarch64_ldadd4_acq_rel` (two underscores; `nm -A` on `outline_atomic_ldadd4_4.S.o`), while only
`___aarch64_have_lse_atomics` has three. Linking fails with `Undefined symbols for architecture arm64: "___aarch64_ldadd4_acq_rel"`,
as an executable and as a dylib. Any tgcalls/WebRTC/TDLib atomic read-modify-write would hit it. The earlier claim that the helpers
"ship in libclang_rt.ios.a" under the called names was wrong.

The iOS simulator arm64 target needs nothing: clang already targets a CPU with LSE and emits `ldaddal` inline. The earlier
`sim_arm64` branches were therefore removed too (they only changed genrule action keys).

## To unblock

- Add a `cc_library` with a small `.S` shim defining every `___aarch64_{cas,swp,ldadd,ldclr,ldeor,ldset}{1,2,4,8,16}_{relax,acq,rel,acq_rel,sync}`
  as `b __aarch64_...`, selected by a config on the same flag; prove a full `tg build --device` links; then measure.
- Done: the floor was raised to 26.0, which defaults to `apple-a12`; the shim is not needed.
- Not needed on Mac (macOS 14 targets `apple-m1`, LSE) or the watch app (prebuilt).

## Guard

`tools/dev/tests/test_outline_atomics.py` keeps the config withdrawn and, when `xcrun` exists, compiles a `fetch_add` file at the floor and asserts inline `ldadd` with no `___aarch64_` calls and no `ldaxr` loop.
