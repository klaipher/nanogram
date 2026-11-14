# twidget (a submodule: klaipher/twidget `nanogram`)

The renderer is no longer a vendored copy. `twidget/` is the submodule https://github.com/klaipher/twidget.git, branch
`nanogram`: Telegram's twidget on the Android line (4769d72, the reorganised layout) plus the macOS branch's commits plus this
app's litehtml and Apple-layer edits (the 91 numbered edits of the old VENDOR.md, as carried, adapted or dropped in the fork's
`NANOGRAM-CHANGES.md`), plus the gumbo limits. One renderer for Nanogram on iOS, macOS and Android (the shared codebase plan,
W3.3 and W3.4). The old text, with the full record of the 91 edits, is `docs/shared/twidget-ios-vendor-history.md`.

What stays here is ours:

| path | what |
|---|---|
| `BUILD` | the targets below, reading the fork's layout (`TW`, `LHP`, `APPLE`, `ASSETS` at its top) |
| `tests/*.cpp`, `tests/test_container.h` | the host tests of the litehtml fork and the deterministic test container |
| `tests/LiteHTMLTests/` | 21 iOS-simulator tests of the Apple layer that differ from the fork's, with `LHTestShim.h` (AppKit spellings and the corpus path). The other 9 (BackgroundImageExclusion, SVGLayerExport, PixelSnap, ColorMatch, FormRendering, SourceFilterCache, PointerEventsHit, FontCache, CSSMath) are byte-identical to `twidget/apple/Tests/LiteHTMLTests` and compiled from the submodule by `FORK_LITEHTML_TESTS` in the BUILD |
| `tests/DocumentTests/` | two Swift renderer tests (DashboardLayout, CompositorClip) that differ from the fork's; DamageBand and CachePurge are byte-identical to `twidget/apple/Tests/TwidgetRendererTests` and compiled from the submodule (`FORK_RENDERER_TESTS`). The 19 that differ stay here until their iOS changes are upstreamed into the fork |
| `shim/Cocoa/Cocoa.h` | a temporary answer to the fork's stray `#import <Cocoa/Cocoa.h>` (below) |

## Where each former path now comes from

| was | now (the submodule) |
|---|---|
| `LiteHTML/litehtml/{src,include}` | `litehtml/{src,include}` |
| `LiteHTML/*.mm`, `*.h`, `core/`, `include/` | `apple/Sources/LiteHTML/` |
| `TwidgetAssets/` | `apple/Sources/TwidgetAssets/` (the icon sources `icons/*`, `icons.json` are there now, unused) |
| `Examples/chats/` | `apple/Examples/chats/` (13 files, five of them newer) |
| `../gumbo/{src,include}` | `litehtml/src/gumbo`, `litehtml/gumbo-include` (`//third-party/twidget:gumbo`; `//third-party/gumbo` is an alias that keeps the html5lib tests) |
| `LICENSE`, `THIRD_PARTY_NOTICES.md` | the fork's |

Consumers include the host-support header as `third-party/twidget/twidget/apple/Sources/LiteHTML/LHHostSupport.h`.

## Fork follow-up (needed before the iOS build)

- `include/LHDocument.h`, `include/LHGPURenderer.h`, `include/LHImages.h`, `include/LHTextFragment.h` and `LHContainer.mm`
  of the fork start with `#import <Cocoa/Cocoa.h>` above the `#if TARGET_OS_OSX` block that imports Foundation, CoreGraphics
  and CoreText for iOS: a merge artifact, the iOS copy had that import inside the guard. The fix is to delete the first line
  of those five files. Until the fork has it, `shim/Cocoa/Cocoa.h` (on `:LiteHTML`'s include path) imports what the guard
  imports, so the layer compiles unchanged; delete the shim and its two BUILD entries with the fork fix.
- Not carried by the fork although this app had them (NANOGRAM-CHANGES.md of the fork): edit 47 (UAX #9 levels through the
  host: the fork's own simplified `reorder_bidi` runs; `bidi_levels` is declared) and the calc trees of edits 48, 49 and 56
  (the fork's 4,096-expression registry). `tests/fork_test.cpp` still has the checks of the iOS behaviour for 46, 47, 48, 49,
  56, 57 and 58 (the blocks from "Edit 46" to the one before "Edit 59"): where the fork's behaviour differs they fail, and the
  decision is the owner's (keep the fork's and rewrite the check, or port the iOS behaviour into the fork).
- C++ standard: the fork's CMake builds the portable half as C++20; this BUILD keeps `-std=gnu++17` for litehtml and the Apple
  layer, as the fork's SwiftPM package does.

## Bazel targets (`BUILD`)

`:litehtml_fork` (the litehtml sources, `-O2`), `:gumbo`, `:TwidgetAssets`, `:LiteHTML` (the Objective-C++ layer; links
`z`, which `LHContainer.mm` needs), the host tests `:TwidgetLitehtmlSmokeTests`, `:TwidgetForkTests`, `:TwidgetExternalTests`,
`:TwidgetSchemeTests`, `:TwidgetProfileHooksTests`, `:TwidgetCssNestingTests`, `:TwidgetCssListsTests`,
`:TwidgetPseudoNestingTests`, the simulator test `:TwidgetRenderingTests`, and `:litehtml_test_container`, `:ScanSources`,
`:GumboScanSources`. The litehtml sources are compiled by this package only: the fork's own `CMakeLists.txt` and
`Package.swift` are not used.
