load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_test.bzl", "cc_test")

# Telegram's gumbo fork (VENDOR.md): the HTML parser behind litehtml and the native widget runtime. Its sources are
# `litehtml/src/gumbo` of the twidget submodule, compiled by `//third-party/twidget:gumbo` (-O2 in every configuration); this
# package keeps the html5lib harness and the fork's own tests.
alias(
    name = "gumbo",
    actual = "//third-party/twidget:gumbo",
    visibility = [
        "//submodules/TelegramUI/Components/MessageWidget/WidgetRuntime:__pkg__",
        "//third-party/twidget:__pkg__",
    ],
)

filegroup(
    name = "Html5libTreeConstruction",
    testonly = True,
    srcs = glob(["tests/html5lib/tree-construction/*.dat"]),
    visibility = ["//submodules/TelegramUI/Components/MessageWidget/WidgetRuntime:__pkg__"],
)

# gumbo's tree in html5lib's format (tests/tree_dump.h).
cc_library(
    name = "tree_dump",
    testonly = True,
    hdrs = ["tests/tree_dump.h"],
    strip_include_prefix = "tests",
    deps = [":gumbo"],
)

# A harness over html5lib's .dat files (tests/html5lib_dat.h): the reader, the expected-failures list, the skip rule,
# gumbo's tree of a case and the driver that counts. GumboHtml5libTests runs on it, and so does WidgetRuntime's builder
# suite, which compares the DOM it makes from gumbo's tree.
cc_library(
    name = "html5lib_dat",
    testonly = True,
    hdrs = ["tests/html5lib_dat.h"],
    strip_include_prefix = "tests",
    deps = [
        ":gumbo",
        ":tree_dump",
    ],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget/WidgetRuntime:__pkg__"],
)

test_copts = [
    "-std=c++20",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wno-unused-parameter",
    "-Ithird-party/gumbo/tests",
]

# html5lib's tree-construction tests through the fork (VENDOR.md, "Tests").
cc_test(
    name = "GumboHtml5libTests",
    srcs = ["tests/html5lib_test.cpp"],
    args = [
        "$(location tests/html5lib-expected-failures.txt)",
        "$(locations :Html5libTreeConstruction)",
    ],
    copts = test_copts,
    data = [
        "tests/html5lib-expected-failures.txt",
        ":Html5libTreeConstruction",
    ],
    deps = [":html5lib_dat"],
)

# Telegram's changes to gumbo (VENDOR.md, "Changes").
cc_test(
    name = "GumboForkTests",
    srcs = [
        "tests/fork_test.cpp",
        "tests/tree_dump.h",
    ],
    copts = test_copts,
    deps = [":gumbo"],
)

# The sources :gumbo compiles, for WidgetRuntime's no-I/O scan (NoIOScanTests).
filegroup(
    name = "ScanSources",
    testonly = True,
    srcs = ["//third-party/twidget:GumboScanSources"],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget/WidgetRuntime:__pkg__"],
)
