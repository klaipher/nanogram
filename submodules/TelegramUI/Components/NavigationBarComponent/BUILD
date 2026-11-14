load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "NavigationBarComponent",
    module_name = "NavigationBarComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/ComponentFlow",
        "//submodules/AppBundle",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        "//submodules/TelegramUI/Components/MoreHeaderButton",
        "//submodules/TelegramUI/Components/SideColumnLayout",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "NavigationBarComponentTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":NavigationBarComponent",
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        "//submodules/TelegramUI/Components/MoreHeaderButton",
        "//submodules/TelegramUI/Components/SideColumnLayout",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15. Matches SideColumnLayoutTests.
ios_test_runner(
    name = "NavigationBarComponentTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "NavigationBarComponentTests",
    minimum_os_version = "26.0",
    runner = ":NavigationBarComponentTestRunner",
    deps = [
        ":NavigationBarComponentTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
