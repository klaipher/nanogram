load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "TelegramAudio",
    module_name = "TelegramAudio",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "TelegramAudioTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":TelegramAudio",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_test_runner(
    name = "TelegramAudioTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "TelegramAudioTests",
    minimum_os_version = "26.0",
    runner = ":TelegramAudioTestRunner",
    deps = [
        ":TelegramAudioTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
