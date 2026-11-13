load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "PremiumCoinComponent",
    module_name = "PremiumCoinComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/ComponentFlow",
        "//submodules/AccountContext",
        "//submodules/AppBundle",
        "//submodules/GZip",
        "//submodules/LegacyComponents",
        "//submodules/Components/MultilineTextComponent:MultilineTextComponent",
        "//submodules/TelegramUI/Components/Premium/PremiumStarComponent",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "PremiumCoinComponentTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":PremiumCoinComponent",
    ],
)

ios_test_runner(
    name = "PremiumCoinComponentTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "PremiumCoinComponentTests",
    minimum_os_version = "15.0",
    runner = ":PremiumCoinComponentTestRunner",
    deps = [
        ":PremiumCoinComponentTestsLib",
    ],
)
