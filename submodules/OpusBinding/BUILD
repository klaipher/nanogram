load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")


# ogg and opusfile come from the single third-party sources (//third-party/ogg v1.3.6, //third-party/opusfile v0.12);
# this module no longer carries its own old copies. SwiftPMLinks/ is for Package.swift only and is not globbed here.
objc_library(
    name = "OpusBinding",
    enable_modules = True,
    module_name = "OpusBinding",
    srcs = glob([
        "Sources/**/*.m",
        "Sources/**/*.c",
        "Sources/**/*.h",
    ]),
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
        "PublicHeaders",
    ],
    copts = [
        "-I{}/Sources".format(package_name()),
        "-I{}/PublicHeaders/OpusBinding".format(package_name()),
    ],
    deps = [
        "//third-party/ogg:ogg",
        "//third-party/opus:opus",
        "//third-party/opusfile:opusfile",
    ],
    sdk_frameworks = [
        "Foundation",
    ],
    visibility = [
        "//visibility:public",
    ],
)


swift_library(
    name = "OpusBindingTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":OpusBinding"],
)

ios_test_runner(
    name = "OpusBindingTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "OpusBindingTests",
    minimum_os_version = "26.0",
    runner = ":OpusBindingTestRunner",
    deps = [":OpusBindingTestsLib"],
)
