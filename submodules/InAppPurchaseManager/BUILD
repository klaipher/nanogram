load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "InAppPurchaseManager",
    module_name = "InAppPurchaseManager",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/PersistentStringHash:PersistentStringHash",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "InAppPurchaseManagerTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":InAppPurchaseManager",
    ],
)

ios_test_runner(
    name = "InAppPurchaseManagerTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "InAppPurchaseManagerTests",
    minimum_os_version = "15.0",
    runner = ":InAppPurchaseManagerTestRunner",
    deps = [
        ":InAppPurchaseManagerTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
