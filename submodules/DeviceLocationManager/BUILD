load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift6_library(
    name = "DeviceLocationManager",
    module_name = "DeviceLocationManager",
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
    name = "DeviceLocationManagerTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":DeviceLocationManager",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "DeviceLocationManagerTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "DeviceLocationManagerTests",
    minimum_os_version = "26.0",
    runner = ":DeviceLocationManagerTestRunner",
    deps = [
        ":DeviceLocationManagerTestsLib",
    ],
)
