load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_test.bzl", "cc_test")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

# twidget's renderer, from the submodule `twidget/` (klaipher/twidget `nanogram`, VENDOR.md): the litehtml fork (pure C++)
# with its gumbo, the icon data (pure C++), and the Objective-C++ layer that lays out and draws with CoreText / CoreGraphics.
# AppKit is guarded out for iOS in the sources themselves. Ours here: this BUILD, the host tests, the iOS test shim.

TW = "twidget"
LHP = TW + "/litehtml"
APPLE = TW + "/apple/Sources/LiteHTML"
ASSETS = TW + "/apple/Sources/TwidgetAssets"
PKG = "third-party/twidget/"
# Test suites that are byte-identical to the fork's own copies (twidget/apple/Tests): compiled from the submodule.
FORK_LITEHTML_TESTS = [
    "BackgroundImageExclusionTests",
    "SVGLayerExportTests",
    "PixelSnapTests",
    "ColorMatchTests",
    "FormRenderingTests",
    "SourceFilterCacheTests",
    "PointerEventsHitTests",
    "FontCacheTests",
    "CSSMathTests",
]
FORK_RENDERER_TESTS = [
    "DamageBandTests",
    "CachePurgeTests",
]
LH = PKG + LHP
AP = PKG + APPLE

# The renderer is optimized in every configuration, as quickjs-ng is: a message widget is laid out and drawn on the
# main thread inside the chat's layout pass, and at -O0 (debug) LiteHTML's parse and layout alone took 1-18 ms per
# widget on boot, which stalled opening and scrolling a chat in the builds everyone runs. Later flags win, so this
# overrides the configuration's -O0.
OPTIMIZE = ["-O2"]

litehtml_copts = OPTIMIZE + [
    "-std=gnu++17",
    "-w",
    "-I" + LH + "/include",
    "-I" + LH + "/include/litehtml",
    "-I" + LH + "/src",
]

# gumbo, which lives in the fork as `litehtml/src/gumbo` and `litehtml/gumbo-include`: Telegram's fork of the HTML5 parser
# with the limits of the widget runtime (//third-party/gumbo keeps its tests and aliases this target). Optimized in every
# configuration, as the renderer and quickjs are: it parses markup inside a widget's boot.
cc_library(
    name = "gumbo",
    srcs = glob([
        LHP + "/src/gumbo/*.c",
        LHP + "/src/gumbo/*.h",
    ]),
    hdrs = glob([LHP + "/gumbo-include/**/*.h"]),
    includes = [LHP + "/gumbo-include"],
    copts = [
        "-O2",
        "-w",
        "-I" + LH + "/src/gumbo",
    ],
    visibility = ["//visibility:public"],
)

# Not "litehtml": that differs from the objc_library "LiteHTML" below only by case, and on a
# case-insensitive file system (APFS default) both targets then write the same bazel-bin paths
# (_objs/litehtml/ and liblitehtml.a == libLiteHTML.a), each archive overwriting the other.
cc_library(
    name = "litehtml_fork",
    srcs = glob([
        LHP + "/src/*.cpp",
        LHP + "/src/*.h",
    ]),
    hdrs = glob([LHP + "/include/**/*.h"]),
    includes = [
        LHP + "/include",
        LHP + "/include/litehtml",
    ],
    copts = litehtml_copts,
    # el_form.cpp formats date and time inputs with CFDateFormatter.
    linkopts = ["-framework", "CoreFoundation"],
    deps = [":gumbo"],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "TwidgetAssets",
    srcs = [ASSETS + "/twa_icons.cpp"],
    hdrs = [ASSETS + "/include/twidget_assets.h"],
    textual_hdrs = [ASSETS + "/twa_icon_data.inc"],
    includes = [ASSETS + "/include"],
    copts = OPTIMIZE + [
        "-std=gnu++17",
        "-w",
        "-I" + PKG + ASSETS,
    ],
    visibility = ["//visibility:public"],
)

objc_library(
    name = "LiteHTML",
    module_name = "LiteHTML",
    enable_modules = True,
    srcs = glob([
        APPLE + "/*.mm",
        APPLE + "/*.h",
        APPLE + "/core/*.cpp",
        APPLE + "/core/*.h",
    ], exclude = [APPLE + "/core/lhx_painter.h", APPLE + "/LHHostSupport.h"]),
    hdrs = glob([APPLE + "/include/*.h"]),
    # The public LHDocumentPainting.h includes "../core/lhx_painter.h" (C++, so not part of the module
    # Swift imports): exported for Objective-C++ dependents, which otherwise cannot find it in their sandbox.
    # LHHostSupport.h is WidgetRuntime's iOS host and painter over LHContainer (M1d plan, Tasks 5 and 6), C++ too.
    textual_hdrs = [APPLE + "/core/lhx_painter.h", APPLE + "/LHHostSupport.h"],
    includes = [APPLE + "/include"],
    copts = OPTIMIZE + [
        "-std=gnu++17",
        "-w",
        "-I" + LH + "/include",
        "-I" + LH + "/include/litehtml",
        "-I" + LH + "/src",
        "-I" + LH + "/gumbo-include",
        "-I" + AP + "/core",
        "-I" + AP,
    ],
    sdk_frameworks = [
        "Foundation",
        "CoreFoundation",
        "CoreGraphics",
        "CoreText",
        "ImageIO",
        "CoreImage",
        "Metal",
        "IOSurface",
        "QuartzCore",
    ],
    # LHContainer.mm inflates PNG rows with zlib.
    sdk_dylibs = ["z"],
    deps = [
        ":litehtml_fork",
        ":TwidgetAssets",
    ],
    visibility = ["//visibility:public"],
)

# Host smoke test of the fork (no Objective-C layer): parse, flex layout, height.
cc_test(
    name = "TwidgetLitehtmlSmokeTests",
    srcs = [
        "tests/smoke_test.cpp",
        "tests/test_container.h",
    ],
    copts = [
        "-std=gnu++17",
        "-w",
        "-Ithird-party/twidget/tests",
    ],
    deps = [":litehtml_fork"],
)

# Host test of Telegram's fork changes (VENDOR.md): tabular-nums, the wrapped-row gap width,
# non-finite transform/box-shadow values parsing as unset, the flex hit test, unfloored line heights and
# the text-piece cap.
cc_test(
    name = "TwidgetForkTests",
    srcs = ["tests/fork_test.cpp", "tests/test_container.h"],
    copts = ["-std=gnu++17", "-w", "-Ithird-party/twidget/tests"],
    deps = [":litehtml_fork"],
)

# The deterministic test container (tests/test_container.h) for host tests outside twidget: WidgetRuntime's own
# container is checked against its metrics.
cc_library(
    name = "litehtml_test_container",
    testonly = True,
    hdrs = ["tests/test_container.h"],
    deps = [":litehtml_fork"],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget/WidgetRuntime:__pkg__"],
)

# Host test of twidget edit 12 (VENDOR.md): a document built from an external DOM, and the master CSS in C++.
cc_test(
    name = "TwidgetExternalTests",
    srcs = ["tests/external_test.cpp", "tests/test_container.h"],
    copts = ["-std=gnu++17", "-w", "-Ithird-party/twidget/tests"],
    deps = [":litehtml_fork"],
)

# Host test of twidget edit 13 (VENDOR.md): prefers-color-scheme, light-dark() and color-scheme, and the caches keyed
# by the scheme.
cc_test(
    name = "TwidgetSchemeTests",
    srcs = ["tests/scheme_test.cpp", "tests/test_container.h"],
    copts = ["-std=gnu++17", "-w", "-Ithird-party/twidget/tests"],
    deps = [":litehtml_fork"],
)

# Host test of twidget edit 29 (VENDOR.md): the profile hooks a container answers (WidgetRuntime's V4 policy).
cc_test(
    name = "TwidgetProfileHooksTests",
    srcs = ["tests/profile_hooks_test.cpp", "tests/test_container.h"],
    copts = ["-std=gnu++17", "-w", "-Ithird-party/twidget/tests"],
    deps = [":litehtml_fork"],
)

# Host test of twidget edit 14 (VENDOR.md): CSS component nesting is bounded, on a 512 KiB stack.
cc_test(
    name = "TwidgetCssNestingTests",
    srcs = ["tests/css_nesting_test.cpp", "tests/test_container.h"],
    copts = ["-std=gnu++17", "-w", "-Ithird-party/twidget/tests"],
    deps = [":litehtml_fork"],
)

# Host test of twidget edit 15 (VENDOR.md): list-valued CSS is capped at parse.
cc_test(
    name = "TwidgetCssListsTests",
    srcs = ["tests/css_lists_test.cpp", "tests/test_container.h"],
    copts = ["-std=gnu++17", "-w", "-Ithird-party/twidget/tests"],
    deps = [":litehtml_fork"],
)

# Host test of twidget edit 19 (VENDOR.md): pseudo-elements never nest and their content is capped, on a 512 KiB stack.
cc_test(
    name = "TwidgetPseudoNestingTests",
    srcs = ["tests/pseudo_nesting_test.cpp", "tests/test_container.h"],
    copts = ["-std=gnu++17", "-w", "-Ithird-party/twidget/tests"],
    deps = [":litehtml_fork"],
)

# twidget's own tests on iOS (tests/, not Tests/: on a case-insensitive file system that is one
# directory with tests/smoke_test.cpp above). Guards are listed in VENDOR.md.

# The seed corpus four LiteHTMLTests suites read, bundled at Examples/chats in the test bundle. Only twidget's own
# tests use it: message widgets are sandbox-only (2026-10-15) and their corpus is widget-sandbox's.
apple_resource_group(
    name = "TwidgetExampleChats",
    testonly = True,
    structured_resources = glob([TW + "/apple/Examples/chats/*.chat"]),
)

objc_library(
    name = "LiteHTMLTestsLib",
    testonly = True,
    # Nine suites are byte-identical to the fork's apple/Tests/LiteHTMLTests and compile from the submodule; the others
    # differ from the fork (iOS expectations) and stay in tests/LiteHTMLTests.
    srcs = glob(
        ["tests/LiteHTMLTests/*.mm"],
        exclude = ["tests/LiteHTMLTests/%s.mm" % n for n in FORK_LITEHTML_TESTS],
    ) + [TW + "/apple/Tests/LiteHTMLTests/%s.mm" % n for n in FORK_LITEHTML_TESTS] + ["tests/LiteHTMLTests/LHTestShim.h"],
    copts = [
        "-std=gnu++17",
        "-w",
        "-I" + LH + "/include",
        "-I" + LH + "/include/litehtml",
        "-I" + LH + "/src",
        "-I" + LH + "/gumbo-include",
        "-I" + AP + "/core",
        "-I" + AP + "/include",
        "-I" + AP,
        # AppKit's NSValue/NSGeometry spellings on iOS, and the corpus directory: see LHTestShim.h.
        "-include",
        "third-party/twidget/tests/LiteHTMLTests/LHTestShim.h",
    ],
    data = [":TwidgetExampleChats"],
    sdk_frameworks = [
        "XCTest",
        "CoreText",
    ],
    deps = [
        ":LiteHTML",
        ":TwidgetAssets",
    ],
)

swift_library(
    name = "DocumentTestsLib",
    testonly = True,
    # DamageBandTests and CachePurgeTests are byte-identical to the fork's apple/Tests/TwidgetRendererTests.
    srcs = glob(
        ["tests/DocumentTests/*.swift"],
        exclude = ["tests/DocumentTests/%s.swift" % n for n in FORK_RENDERER_TESTS],
    ) + [TW + "/apple/Tests/TwidgetRendererTests/%s.swift" % n for n in FORK_RENDERER_TESTS],
    deps = [":LiteHTML"],
)

ios_test_runner(
    name = "TwidgetTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "TwidgetRenderingTests",
    minimum_os_version = "26.0",
    runner = ":TwidgetTestRunner",
    # ~100 s in the simulator at -O0 (DamageBandTests' 480 renders take 40 s, DocumentFuzzTests' 400
    # documents 12 s), before the runner's own overhead.
    timeout = "long",
    deps = [
        ":LiteHTMLTestsLib",
        ":DocumentTestsLib",
    ],
)

# The sources :litehtml_fork compiles, for WidgetRuntime's no-I/O scan (NoIOScanTests).
filegroup(
    name = "ScanSources",
    testonly = True,
    srcs = glob([
        LHP + "/src/*.cpp",
        LHP + "/src/*.h",
        LHP + "/include/**/*.h",
    ]),
    visibility = ["//submodules/TelegramUI/Components/MessageWidget/WidgetRuntime:__pkg__"],
)

# The sources and headers :gumbo compiles, for the same scan and for //third-party/gumbo:ScanSources.
filegroup(
    name = "GumboScanSources",
    testonly = True,
    srcs = glob([
        LHP + "/src/gumbo/*.c",
        LHP + "/src/gumbo/*.h",
        LHP + "/gumbo-include/**/*.h",
    ]),
    visibility = ["//third-party/gumbo:__pkg__"],
)
