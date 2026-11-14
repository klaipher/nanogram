# Outline atomics (SHARED-APPLE-CPU-1): BLOCKED

Status: blocked, the `--config=outline_atomics` opt-in was withdrawn. A device build with `-moutline-atomics` does not link.

## Why it was proposed

`Telegram/BUILD` sets `minimum_os_version = "15.0"`, so clang compiles for `apple-a7` without LSE: every `std::atomic`
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
- Or, when the iOS floor is raised (16/17), use `-mcpu=apple-a11/a12` instead and skip this.
- Not needed on Mac (macOS 14 targets `apple-m1`, LSE) or the watch app (prebuilt).

## Guard

`tools/dev/tests/test_outline_atomics.py` keeps the config withdrawn and, when `xcrun` exists, compiles and links a `fetch_add`
file with `-moutline-atomics` for iOS to document the failure. If Apple fixes the symbol names that test fails: then revisit this.
