# W3.4 (iOS widget stack): what was compared before the vendored copies were deleted

Same rule as `w2-i1-identity-proofs.md`: comparisons made against the old copy at the parent commit of each W3.4 commit.
Nothing here was built or run.

## quickjs (klaipher/quickjs `nanogram` f6fc68b9, base TelegramMessenger/quickjs b526a817)

- Old copy: `third-party/quickjs-ng/quickjs/*` (quickjs-ng v0.17.0 + iOS changes 3-7, 9, 10, 12 + the 21 security fixes of
  change 14) and `include/quickjs.h`.
- Identical to the fork: `libregexp.c`, `libunicode.c`, `cutils.h`, `list.h`, `libregexp.h`, `libunicode.h`, `dtoa.h`,
  `quickjs-opcode.h`, `quickjs-c-atomics.h`, `libregexp-opcode.h`, `libunicode-table.h`.
- Different, and why (changed lines of `diff old fork`): `quickjs.c` 1429, `dtoa.c` 311, `builtin-iterator-zip.h` 479,
  `builtin-iterator-zip-keyed.h` 461, `builtin-array-fromasync.h` 201, `quickjs-atom.h` 1, `quickjs.h` 34. These are
  b526a817's own changes against quickjs-ng v0.17.0 (arenas, the `uncatchable_pending` model, the interrupt handler's
  `JSContext*`, `await using` and other fixes) plus the one place the fork re-expresses iOS change 10. The fork's
  `NANOGRAM-CHANGES.md` has the provenance proof (iOS `quickjs.c` diff against v0.17.0, three-way merged onto b526a817: equal to
  the branch but for change 10 and one comment).
- API: every `JS_*` name the shim, the C tests, WidgetRuntime and WidgetRuntimeIOS use is declared in the fork's `quickjs.h`
  (a grep of 243 names; the only misses are in comments and the removed work-counter names the scan tests look for).
  The one signature change is `JSInterruptHandler(JSContext*, void*)`.
- `WidgetRuntimeNoIOScanTests` (pure-Python port of the scanner, run over the compiled sources and headers): one hit, the
  arenas' anonymous `mmap` at `quickjs.c:1893`; allowlisted. `WidgetRuntimeNoWorkUnitsScanTests`: no hit.
