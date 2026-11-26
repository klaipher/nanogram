load("@rules_cc//cc:cc_test.bzl", "cc_test")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

objc_library(
    name = "CpuProfiler",
    enable_modules = True,
    module_name = "CpuProfiler",
    srcs = glob([
        "Sources/*.mm",
        "Sources/*.h",
    ]),
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
        "PublicHeaders",
    ],
    copts = [
        "-std=c++17",
    ],
    sdk_frameworks = [
        "Foundation",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host (macOS) test of the call-tree line format, run with `bazel test`, like the libprisma and tgcalls cc_tests.
cc_test(
    name = "CallTreeLineTests",
    srcs = [
        "Sources/CallTreeLine.h",
        "Tests/CallTreeLineTests.cpp",
    ],
    copts = [
        "-std=c++17",
        "-Isubmodules/CpuProfiler/Sources",
    ],
)
