# widget-sandbox (a submodule: klaipher/widget-sandbox `nanogram`)

The framework is no longer a vendored subset. `widget-sandbox/` is the submodule https://github.com/klaipher/widget-sandbox.git,
branch `nanogram`: Telegram's v0.6.3 line (Android's c498cef) plus the macOS app's Swift remote engine and bubble safe-area
commits, with the nested QuickJS pointing at klaipher/quickjs. One framework for Nanogram on iOS, macOS and Android (the
shared codebase plan, W3.2 and W3.4). The fork's record is `widget-sandbox/NANOGRAM-CHANGES.md`. The text of the old numbered
vendoring notes (v0.5.0 subset, the tag-by-tag history, the unedited-copy commands) is in git history:
`git show <the commit that added this version>^:third-party/widget-sandbox/VENDOR.md`.

What stays in this package is ours:

| path | what |
|---|---|
| `BUILD` | the targets below, reading the submodule's layout (`WS`, `CORPUS`, `CONFORMANCE`, `STRESS`, `FIXTURES`, `SANDBOX` at its top) |
| `ios/WidgetSandboxIntl.swift`, `ios/Tests/` | the public entry of the Intl glue and its test, on the Intl fixture |
| `gesture/{GesturePolicy,SdkPolicy,CpuBudget}Tests.cpp` | our hosts for the shared-fixture tests of upstream's C++ policies |

## Where each former copy now comes from

| was (v0.5.0, copied) | now (the submodule) |
|---|---|
| `corpus/` | `widget-sandbox/corpus/` |
| `conformance/` | `widget-sandbox/packages/conformance/` (`tools/report.mjs` for `Tests/WidgetHarness/Tools/conformance_report.sh`) |
| `stress/` | `widget-sandbox/packages/stress/` |
| `profile/profile.json` | `widget-sandbox/packages/core/profile.json` (`IDL/generate-profile-tables.py` reads it) |
| `fixtures/{intl-cases,gesture-policy,sdk-policy,cpu-budget}.json` | `widget-sandbox/packages/core/tests/fixtures/` |
| `gesture/twidget/*.h`, `gesture/*.cpp` | `widget-sandbox/packages/desktop/sandbox/{include/twidget,src}/` |
| `ios/PluralRules.swift` | `widget-sandbox/packages/ios/Sources/WidgetSandbox/PluralRules.swift` |
| `ios/IntlBridge.swift` (the "Intl delegation" tail of `SandboxEngine.swift`, after an `import Foundation`) | the genrule `:IntlBridgeSource`, which cuts it out of the submodule's `SandboxEngine.swift` at build time (the bytes equal the old copy's when the source is unchanged) |

Resource bundles: the test groups `:WidgetCorpus` and `:WidgetConformance` now carry the submodule's paths
(`widget-sandbox/corpus/…`, `widget-sandbox/packages/conformance/…`) inside a test bundle; the harness bundles
(`:WidgetCorpusBundle`, `:WidgetConformanceBundle`, `:WidgetStressBundle`) strip them, so the app's layout is unchanged.
`:WidgetConformance` no longer carries the web harness, `results/` or `catalogue.md`.

## v0.5.0 to the v0.6.3 line: what this runtime does not follow yet

The tests were re-baselined (conformance 68 auto + 47 visual tests in 121 theme runs, channel 122 posts, corpus 279 files
without `attacks/`, 127 attack pages), but WidgetRuntime was not ported to the new limits. Follow-ups, each deferred to a run:

- the paint limits (profile decision L2: at most 16 heavy boxes, 2 with a backdrop filter; `auto/37`-`43`, the `paint-*`
  attack pages) and the 2,000-node cap (`auto/44-stop-nodes`; this runtime allows 50,000, the old profile's number);
- the canvas command cap (4,000 per canvas in one task, was 10,000; `auto/19-limits`) and the batch wording of `auto/33`;
- the layout-query limit (128 queries and 1,000 ms per task; this runtime keeps its own 100 ms and counts no queries);
- the CPU quota's debt model is in (`CpuBudget`: whole slice for every task, no floor), and so are its test changes.

`Tests/WidgetHarness/Conformance/baseline.json` has to be re-recorded after a run (`Tools/conformance_report.sh --record`):
eight tests and 12 checks are new, and `auto/19` and `auto/33` changed their checks. Corpus goldens
(`WidgetRuntime/Tests/CorpusGoldens`): `bot-demos/07-wallet.html` is new and twelve pages changed; regenerate with
`WR_GOLDENS_UPDATE=1` (the header of `CorpusGoldenTests.cpp`).
