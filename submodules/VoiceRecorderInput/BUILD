load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

objc_library(
    name = "VoiceRecorderInput",
    enable_modules = True,
    module_name = "VoiceRecorderInput",
    srcs = glob([
        "Sources/*.c",
    ]),
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
        "PublicHeaders",
    ],
    copts = [
        "-Werror",
        "-std=c11",
    ],
    sdk_frameworks = [
        "AudioToolbox",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "VoiceRecorderInputTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":VoiceRecorderInput",
        "//submodules/OpusBinding:OpusBinding",
    ],
)

ios_test_runner(
    name = "VoiceRecorderInputTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "VoiceRecorderInputTests",
    minimum_os_version = "15.0",
    runner = ":VoiceRecorderInputTestRunner",
    deps = [
        ":VoiceRecorderInputTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
