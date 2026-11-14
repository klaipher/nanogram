load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_test.bzl", "cc_test")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

quickjs_copts = [
    "-O2",
    "-w",
    "-D_GNU_SOURCE",
    "-Ithird-party/quickjs-ng/include",
    "-Ithird-party/quickjs-ng/quickjs",
]

cc_library(
    name = "quickjs",
    srcs = [
        "quickjs/quickjs.c",
        "quickjs/dtoa.c",
        "quickjs/libregexp.c",
        "quickjs/libunicode.c",
        "shim/qjs_shim.c",
    ] + glob(["quickjs/*.h"]),
    hdrs = [
        "quickjs/quickjs.h",
        "include/qjs_shim.h",
    ],
    includes = [
        "include",
        "quickjs",
    ],
    copts = quickjs_copts,
    visibility = ["//visibility:public"],
)

objc_library(
    name = "CQuickJS",
    module_name = "CQuickJS",
    enable_modules = True,
    hdrs = [
        "quickjs/quickjs.h",
        "include/qjs_shim.h",
    ],
    includes = [
        "include",
        "quickjs",
    ],
    deps = [":quickjs"],
    visibility = ["//visibility:public"],
)

cc_test(
    name = "QuickJSSmokeTests",
    srcs = ["tests/quickjs_smoke_test.c"],
    copts = quickjs_copts,
    deps = [":quickjs"],
)

# The fork's host API (klaipher/quickjs `nanogram`, its NANOGRAM-CHANGES.md; the numbered changes 3-10 and 12 of the
# retired VENDOR.md): host auto-init properties, class prototypes on first use, string access, a host-class global object,
# host time and randomness, a host hook at the memory limit, the host's stop, no dumps without an explicit opt-in.
cc_test(
    name = "QuickJSHostTests",
    srcs = ["tests/quickjs_host_test.c"],
    copts = quickjs_copts,
    deps = [":quickjs"],
)

# Published triggers for memory-safety bugs reachable from a message widget's script (the fixes come with the fork's base,
# TelegramMessenger/quickjs b526a817). Also run it
# with --features=asan: the use-after-free cases only show under AddressSanitizer.
cc_test(
    name = "QuickJSSecurityTests",
    srcs = ["tests/quickjs_security_test.c"],
    copts = quickjs_copts,
    deps = [":quickjs"],
)

# The sources :quickjs compiles, for WidgetRuntime's no-I/O scan (NoIOScanTests).
filegroup(
    name = "ScanSources",
    testonly = True,
    srcs = [
        "quickjs/quickjs.c",
        "quickjs/dtoa.c",
        "quickjs/libregexp.c",
        "quickjs/libunicode.c",
        "shim/qjs_shim.c",
    ] + glob(["quickjs/*.h", "include/*.h"]),
    visibility = ["//submodules/TelegramUI/Components/MessageWidget/WidgetRuntime:__pkg__"],
)
