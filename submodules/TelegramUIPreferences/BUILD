load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "TelegramUIPreferences",
    module_name = "TelegramUIPreferences",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/HardenedMedia",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "TelegramUIPreferencesTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":TelegramUIPreferences",
        "//submodules/HardenedMedia",
    ],
)

ios_test_runner(
    name = "TelegramUIPreferencesTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "TelegramUIPreferencesTests",
    minimum_os_version = "15.0",
    runner = ":TelegramUIPreferencesTestRunner",
    deps = [
        ":TelegramUIPreferencesTestsLib",
    ],
)
