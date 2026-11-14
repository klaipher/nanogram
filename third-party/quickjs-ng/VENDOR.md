# QuickJS (a submodule: klaipher/quickjs `nanogram`)

The engine is no longer a vendored copy. `quickjs/` is the submodule https://github.com/klaipher/quickjs.git, branch
`nanogram`: TelegramMessenger/quickjs `b526a817` (quickjs-ng v0.17.0 plus the tdesktop memory-safety fixes the Mac app
already ran) plus the host API of the widget runtime, one commit per change. One engine for Nanogram on iOS, macOS and
Android (the shared codebase plan, W3.1). What is ours here is the glue: `BUILD`, `shim/` (the C layer for Swift),
`include/qjs_shim.h` and `tests/`.

The fork's own record, which says what differs from Telegram's and why, is `quickjs/NANOGRAM-CHANGES.md`. The numbered
changes of the retired copy of this file map as follows. The long text of each is in git history:
`git show <the commit that added this version>^:third-party/quickjs-ng/VENDOR.md`.

| change | now |
|---|---|
| 1 (interrupt poll every 100 operations), 2 (work counter), 11 (charged module walks) | gone before the move (2026-10-30), as before |
| 3 host auto-init, 4 class prototypes on first use, 5 string access, 6 host-class global, 7 host time and randomness, 9 memory-limit hook, 12 no dumps without `TELEGRAM_QJS_ENABLE_DUMPS` | the fork's commits of the same names |
| 8 uncatchable error through a Promise executor | in b526a817 already (its `uncatchable_pending` model) |
| 10 the host's stop (`JS_SetStopped`) | re-expressed on b526a817's `uncatchable_pending`: after the stop every poll throws the uncatchable "interrupted" error itself and the interrupt handler is not asked again |
| 13, 14 (the 21 security and crash fixes from b526a81) | in the base |

## What changed for this app

- `JSInterruptHandler` takes the `JSContext*` (b526a817's signature; quickjs-ng v0.17.0 passed the `JSRuntime*`):
  `Runtime::interrupt` and the three test handlers changed with it.
- The engine's interface header is `quickjs/quickjs.h`; `BUILD` puts `quickjs/` and `include/` on the include path
  (`include/qjs_shim.h` includes it), and `-DQUICKJS_NG_BUILD` is gone (it only mattered on Windows).
- The arenas of b526a817 map their slabs with an anonymous `mmap`; `WidgetRuntimeNoIOScanTests` lists that one line in
  its allowlist, with the reason.
- The nested `test262` submodule is `update = none` in the fork's `.gitmodules`, so `git submodule update --recursive`
  does not fetch it.

## Updating

Change the engine in the fork (branch `nanogram`), push it, then move the gitlink here:
`git -C third-party/quickjs-ng/quickjs fetch && git -C third-party/quickjs-ng/quickjs checkout <sha>`, commit
`third-party/quickjs-ng/quickjs`, and record the same sha for the Mac and Android pins. Never edit the checkout in place.
