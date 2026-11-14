load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "CoreListComponentHost",
    module_name = "CoreListComponentHost",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display:Display",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/TelegramUI/Components/CoreList:CoreList",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "CoreListComponentHostTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":CoreListComponentHost",
        "//submodules/Display:Display",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/TelegramUI/Components/CoreList:CoreList",
    ],
)

ios_test_runner(
    name = "CoreListComponentHostTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "CoreListComponentHostTests",
    minimum_os_version = "26.0",
    runner = ":CoreListComponentHostTestRunner",
    deps = [
        ":CoreListComponentHostTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
