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

## widget-sandbox (klaipher/widget-sandbox `nanogram` 1b21a48e)

Old copy: v0.5.0 subset at `third-party/widget-sandbox` (parent of the commit). New source: the submodule, which is the v0.6.3
line, so most data differs by design; what was compared:

- Byte-identical to the fork: `gesture/twidget/{gesture_policy,json}.h`, `gesture/{gesture_policy,sdk_policy}.cpp`,
  `fixtures/{intl-cases,gesture-policy,sdk-policy}.json`, `ios/PluralRules.swift`.
- `ios/IntlBridge.swift` equals `import Foundation`, a blank line, then the fork's `SandboxEngine.swift` from its
  `// MARK: - Intl delegation` line to the end: no diff (this is what the genrule `:IntlBridgeSource` produces).
- Changed upstream (v0.6.x): `sdk_policy.h` (8 lines: `PROFILE_VERSION` from `twidget/version.h`, now in the `SdkPolicy`
  headers), `cpu_budget.h` and `cpu_budget.cpp` (the debt model, `queryLimitHit`; no `kFloorMs`, no `queryBudgetMs`),
  `fixtures/cpu-budget.json` (437 diff lines), `profile.json` (33 lines: L2 paint-limit decision and limit titles; the regenerated
  `ProfileTables.inc` is identical to the old one but for its two header comment lines).
- Manifest: no test removed; added `auto/37-paint-counted`, `auto/38`-`44` (seven stop tests); changed: `auto/19-limits`
  (canvas commands 4000) and `auto/33-stop-batch` (wording). Meta and `message`/`bot`/`host`/`actions` of every other test
  are equal, so the assertions of `ConformanceRunnerTests` that read them stand. Counts: auto 68 tests / 70 theme runs,
  visual 47 / 51 (unchanged), 637 expected checks (was 625).
- Channel: 122 posts, 69 `auto/`, 16 with a `message`, 4 not captioned below (same four); stress manifest: 127 widgets;
  corpus `.html` files per folder: attacks 127 (+14), bot-demos 7 (+1, `07-wallet`), the others as before (generated 40 =
  20 + 20, htmlbubbles-ported 116, showcase 27, ...); twelve existing pages changed.

## twidget and gumbo (klaipher/twidget `nanogram` a4f5391c)

- gumbo: `diff -r third-party/gumbo/src litehtml/src/gumbo` and `diff -r third-party/gumbo/include litehtml/gumbo-include`
  (fork tree, a4f5391c): no difference. So the 13 changes, `GumboForkTests` and the html5lib verdicts (1,792 cases in 57
  files, 1,747 pass, 31 listed failures, 14 skipped) are unchanged; `gumbo/tests` stays here and runs against the fork's files.
- `TwidgetAssets`: `twa_icons.cpp`, `twa_icon_data.inc`, `include/twidget_assets.h`, `icons/LICENSE` identical to the fork's
  `apple/Sources/TwidgetAssets/`; the fork adds the icon sources (`icons/{light,regular,bold,fill}`, `icons.json`), not built.
- `LICENSE` identical; `THIRD_PARTY_NOTICES.md` differs (the fork's is current).
- Apple layer, iOS copy against the fork (changed lines of `diff`): identical `LHGPURenderer.mm`, `LHRenderList.mm`,
  `LHSanitizer.mm`, `LHFilters.h`, `LHGPUInternal.h`, `LHHostSupport.h`, `core/lhx_sanitizer.*`, `include/LHDocumentPainting.h`,
  `include/LHRenderList.h`, `include/LHSanitizer.h`; different: `LHContainer.mm` 803, `LHDocument.mm` 1960 (the Mac renderer's
  patch, cache and selection APIs, the image policy merge, `TWClipPath`), `LHImages.mm` 6, `LHFilters.mm` 2, `LHSimpleText.*`
  4 and 6, `LHContainer.h` 12, `LHDocument.h` 71 (added methods only, plus the stray Cocoa import below), `core/lhx_painter.h` 6.
  `LHDocument.h` keeps every method the iOS copy declared (the diff has only additions on the fork side).
- Defect found: the fork's `include/{LHDocument,LHGPURenderer,LHImages,LHTextFragment}.h` and `LHContainer.mm` begin with an
  unguarded `#import <Cocoa/Cocoa.h>`. `third-party/twidget/shim/Cocoa/Cocoa.h` covers it (VENDOR.md, "Fork follow-up").
- litehtml: the fork has `litehtml/src/*.cpp|h` 66 files and `include/**/*.h` 76; the old copy had `calc_node.{h,cpp}` that the
  fork does not (its calc registry replaces them). `-std=gnu++17` as before; the fork's SwiftPM package uses the same.
- `WidgetRuntimeNoIOScanTests`, the pure-Python port over the 171 litehtml and gumbo files: no hit. Thresholds: litehtml files
  >= 140 (was 128; 66 + 76 + 27 + 2 + ... = 171 counted), gumbo >= 26 (29 files), quickjs >= 20 (was 16; 22 files).
