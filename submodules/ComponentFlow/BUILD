load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ComponentFlow",
    module_name = "ComponentFlow",
    srcs = glob([
        "Source/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/UIKitRuntimeUtils",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Tests for ComponentAccessibility, the accessibility parameter of the four button components and the list row components. The test lib depends
# on the component packages (they depend on ComponentFlow, not the other way round, so there is no cycle).
swift_library(
    name = "ComponentFlowTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ComponentFlow",
        "//submodules/Display",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/Components/BalancedTextComponent",
        "//submodules/Components/BundleIconComponent",
        "//submodules/Markdown",
        "//submodules/TelegramUI/Components/ButtonComponent",
        "//submodules/TelegramUI/Components/PlainButtonComponent",
        "//submodules/TelegramUI/Components/GlassBarButtonComponent",
        "//submodules/TelegramUI/Components/ListActionItemComponent",
        "//submodules/TelegramUI/Components/ListSectionComponent",
        "//submodules/TelegramUI/Components/ListSwitchItemComponent",
        "//submodules/TelegramPresentationData",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "ComponentFlowTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ComponentFlowTests",
    minimum_os_version = "26.0",
    runner = ":ComponentFlowTestRunner",
    deps = [
        ":ComponentFlowTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
