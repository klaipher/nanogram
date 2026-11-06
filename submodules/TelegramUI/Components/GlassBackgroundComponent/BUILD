load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "GlassBackgroundComponent",
    module_name = "GlassBackgroundComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/ComponentFlow",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/UIKitRuntimeUtils",
        "//submodules/AppBundle",
        "//submodules/TelegramUI/Components/MeshTransform",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "GlassBackgroundComponentTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":GlassBackgroundComponent",
        "//submodules/UIKitRuntimeUtils",
    ],
)

# The runner MUST pin a real device/OS (see NavigationBarNode/BUILD).
ios_test_runner(
    name = "GlassBackgroundComponentTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "GlassBackgroundComponentTests",
    minimum_os_version = "15.0",
    runner = ":GlassBackgroundComponentTestRunner",
    deps = [
        ":GlassBackgroundComponentTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
