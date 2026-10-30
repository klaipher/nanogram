
load("@rules_cc//cc:objc_library.bzl", "objc_library")

objc_library(
    name = "MtProtoKit",
    enable_modules = True,
    module_name = "MtProtoKit",
    srcs = glob([
        "Sources/**/*.m",
        "Sources/**/*.h",
    ]),
    copts = [
        "-Werror",
    ],
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
        "PublicHeaders",
    ],
    deps = [
        "//submodules/EncryptionProvider:EncryptionProvider",
    ],
    sdk_frameworks = [
        "Foundation",
        "Security",
        "SystemConfiguration",
        "CFNetwork",
    ],
    sdk_dylibs = [
        "libz",
    ],
    visibility = [
        "//visibility:public",
    ],
)

load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

# Module-private headers, exposed to the tests only, so a test can
# `#import "MTInternalMessageParser.h"` the way the module's own sources do.
objc_library(
    name = "MtProtoKitPrivateHeaders",
    testonly = True,
    hdrs = glob([
        "Sources/**/*.h",
    ]),
    includes = [
        "Sources",
    ],
    deps = [
        ":MtProtoKit",
    ],
)

objc_library(
    name = "MtProtoKitTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.m",
        "Tests/**/*.h",
    ]),
    deps = [
        ":MtProtoKit",
        ":MtProtoKitPrivateHeaders",
    ],
    sdk_frameworks = [
        "XCTest",
    ],
)

ios_test_runner(
    name = "MtProtoKitTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "MtProtoKitTests",
    minimum_os_version = "15.0",
    runner = ":MtProtoKitTestRunner",
    deps = [
        ":MtProtoKitTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
